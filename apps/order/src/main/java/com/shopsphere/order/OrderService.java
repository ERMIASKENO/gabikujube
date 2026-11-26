package com.shopsphere.order;

import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

import io.micrometer.core.instrument.MeterRegistry;

/**
 * Checkout orchestration (synchronous saga with compensation points):
 * cart -> price -> reserve stock -> quote shipping -> charge -> clear cart -> publish event.
 * The order-events message lets notification (and future consumers) react
 * asynchronously without order knowing about them.
 */
@Service
public class OrderService {

    public record Line(String productId, int quantity) {}
    public record Order(String orderId, String userId, String status, long totalCents, List<Line> items) {}

    private final RestClient http;
    private final EventPublisher events;
    private final MeterRegistry meters;
    private final Map<String, Order> orders = new ConcurrentHashMap<>();      // production: PostgreSQL
    private final Map<String, String> idempotency = new ConcurrentHashMap<>(); // key -> orderId

    @Value("${services.cart}") String cartUrl;
    @Value("${services.catalog}") String catalogUrl;
    @Value("${services.inventory}") String inventoryUrl;
    @Value("${services.shipping}") String shippingUrl;
    @Value("${services.payment}") String paymentUrl;

    public OrderService(RestClient http, EventPublisher events, MeterRegistry meters) {
        this.http = http;
        this.events = events;
        this.meters = meters;
    }

    static long total(Map<String, Long> unitPrices, List<Line> items, long shippingCents) {
        return items.stream().mapToLong(l -> unitPrices.getOrDefault(l.productId(), 0L) * l.quantity()).sum() + shippingCents;
    }

    public Order find(String id) {
        return orders.get(id);
    }

    @SuppressWarnings("unchecked")
    public Order placeOrder(String userId, String country, String cardToken, String idempotencyKey) {
        if (idempotencyKey != null && idempotency.containsKey(idempotencyKey)) {
            return orders.get(idempotency.get(idempotencyKey));
        }
        String orderId = "ord_" + UUID.randomUUID();

        Map<String, Object> cart = http.get().uri(cartUrl + "/api/cart/{u}", userId).retrieve().body(Map.class);
        List<Map<String, Object>> raw = (List<Map<String, Object>>) cart.getOrDefault("items", List.of());
        List<Line> items = raw.stream()
                .map(m -> new Line((String) m.get("productId"), ((Number) m.get("quantity")).intValue())).toList();
        if (items.isEmpty()) {
            throw new IllegalStateException("cart is empty");
        }

        Map<String, Long> prices = new java.util.HashMap<>();
        for (Line l : items) {
            Map<String, Object> p = http.get().uri(catalogUrl + "/api/products/{id}", l.productId()).retrieve().body(Map.class);
            prices.put(l.productId(), ((Number) p.get("priceCents")).longValue());
        }

        http.post().uri(inventoryUrl + "/api/inventory/reserve").contentType(MediaType.APPLICATION_JSON)
                .body(Map.of("orderId", orderId, "items", items)).retrieve().toBodilessEntity();

        Map<String, Object> quote = http.post().uri(shippingUrl + "/api/shipping/quote").contentType(MediaType.APPLICATION_JSON)
                .body(Map.of("country", country, "items", items.stream().mapToInt(Line::quantity).sum()))
                .retrieve().body(Map.class);
        long totalCents = total(prices, items, ((Number) quote.get("costCents")).longValue());

        Map<String, Object> payment = http.post().uri(paymentUrl + "/api/payments/charge")
                .header("Idempotency-Key", orderId) // safe for Istio to retry
                .contentType(MediaType.APPLICATION_JSON)
                .body(Map.of("orderId", orderId, "amountCents", totalCents, "currency", "EUR", "cardToken", cardToken))
                .retrieve().body(Map.class);
        String status = "approved".equals(payment.get("status")) ? "paid" : "payment_declined";
        // compensation for declined payments (release reservation) would go here

        if ("paid".equals(status)) {
            http.delete().uri(cartUrl + "/api/cart/{u}", userId).retrieve().toBodilessEntity();
        }

        Order order = new Order(orderId, userId, status, totalCents, items);
        orders.put(orderId, order);
        if (idempotencyKey != null) {
            idempotency.put(idempotencyKey, orderId);
        }
        meters.counter("orders_placed_total", "status", status).increment();
        events.publish(Map.of("type", "OrderPlaced", "orderId", orderId, "status", status, "totalCents", totalCents, "currency", "EUR"));
        return order;
    }
}
