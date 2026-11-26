package com.shopsphere.order;

import java.util.Map;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClientResponseException;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    public record PlaceOrderRequest(@NotBlank String userId, @NotBlank String country, @NotBlank String cardToken) {}

    private final OrderService service;

    public OrderController(OrderService service) {
        this.service = service;
    }

    @PostMapping
    public ResponseEntity<OrderService.Order> place(@Valid @RequestBody PlaceOrderRequest req,
                                                    @RequestHeader(value = "Idempotency-Key", required = false) String key) {
        var order = service.placeOrder(req.userId(), req.country(), req.cardToken(), key);
        return ResponseEntity.status(HttpStatus.CREATED).body(order);
    }

    @GetMapping("/{id}")
    public ResponseEntity<OrderService.Order> get(@PathVariable String id) {
        var order = service.find(id);
        return order == null ? ResponseEntity.notFound().build() : ResponseEntity.ok(order);
    }

    @ExceptionHandler(IllegalStateException.class)
    ResponseEntity<Map<String, String>> badState(IllegalStateException e) {
        return ResponseEntity.unprocessableEntity().body(Map.of("error", e.getMessage()));
    }

    /** Downstream 409 (out of stock) etc. is surfaced as-is; 5xx becomes 502. */
    @ExceptionHandler(RestClientResponseException.class)
    ResponseEntity<Map<String, String>> downstream(RestClientResponseException e) {
        var code = e.getStatusCode().is4xxClientError() ? e.getStatusCode() : HttpStatus.BAD_GATEWAY;
        return ResponseEntity.status(code).body(Map.of("error", "downstream: " + e.getStatusText()));
    }
}
