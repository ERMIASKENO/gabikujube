package com.shopsphere.order;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

class OrderServiceTest {

    @Test
    void totalIncludesQuantitiesAndShipping() {
        var prices = Map.of("a", 1000L, "b", 250L);
        var items = List.of(new OrderService.Line("a", 2), new OrderService.Line("b", 4));
        assertThat(OrderService.total(prices, items, 499)).isEqualTo(2000 + 1000 + 499);
    }

    @Test
    void unknownProductCountsAsZero() {
        assertThat(OrderService.total(Map.of(), List.of(new OrderService.Line("x", 3)), 0)).isZero();
    }
}
