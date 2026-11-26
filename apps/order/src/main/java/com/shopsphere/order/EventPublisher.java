package com.shopsphere.order;

import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.messaging.servicebus.ServiceBusClientBuilder;
import com.azure.messaging.servicebus.ServiceBusMessage;
import com.azure.messaging.servicebus.ServiceBusSenderClient;
import com.fasterxml.jackson.databind.ObjectMapper;

/**
 * Publishes domain events to the Service Bus topic `order-events`.
 * Auth: DefaultAzureCredential -> Workload Identity federated token (AKS).
 * If SERVICEBUS_FQDN is empty (local dev, tests) events are only logged.
 *
 * Production hardening: use the transactional outbox pattern (write the event
 * to the orders DB in the same transaction, relay asynchronously) to avoid
 * "order saved but event lost" on crashes.
 */
@Component
public class EventPublisher implements DisposableBean {

    private static final Logger log = LoggerFactory.getLogger(EventPublisher.class);
    private final ObjectMapper json = new ObjectMapper();
    private final ServiceBusSenderClient sender;

    public EventPublisher(@Value("${servicebus.fqdn:}") String fqdn, @Value("${servicebus.topic:order-events}") String topic) {
        this.sender = fqdn.isBlank() ? null : new ServiceBusClientBuilder()
                .fullyQualifiedNamespace(fqdn)
                .credential(new DefaultAzureCredentialBuilder().build())
                .sender().topicName(topic).buildClient();
    }

    public void publish(Map<String, Object> event) {
        try {
            String body = json.writeValueAsString(event);
            if (sender == null) {
                log.info("event (not published, no Service Bus configured): {}", body);
                return;
            }
            var msg = new ServiceBusMessage(body).setContentType("application/json")
                    .setMessageId(String.valueOf(event.get("orderId"))); // enables duplicate detection
            sender.sendMessage(msg);
        } catch (Exception e) {
            log.error("failed to publish event", e);
        }
    }

    @Override
    public void destroy() {
        if (sender != null) {
            sender.close();
        }
    }
}
