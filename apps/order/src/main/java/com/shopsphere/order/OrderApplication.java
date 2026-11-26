package com.shopsphere.order;

import java.time.Duration;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

@SpringBootApplication
public class OrderApplication {

    public static void main(String[] args) {
        SpringApplication.run(OrderApplication.class, args);
    }

    /**
     * One RestClient with tight timeouts. Retries/circuit-breaking are done by
     * the Istio sidecar (VirtualService retries + DestinationRule outlier
     * detection), so the app does not double-retry and amplify load.
     */
    @Bean
    RestClient restClient(@Value("${clients.connect-timeout:500ms}") Duration connect,
                          @Value("${clients.read-timeout:2s}") Duration read) {
        var factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(connect);
        factory.setReadTimeout(read);
        return RestClient.builder().requestFactory(factory).build();
    }
}
