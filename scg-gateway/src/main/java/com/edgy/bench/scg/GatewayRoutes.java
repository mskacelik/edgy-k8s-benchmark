package com.edgy.bench.scg;

import java.time.Instant;

import org.springframework.cloud.gateway.route.RouteLocator;
import org.springframework.cloud.gateway.route.builder.RouteLocatorBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import reactor.core.publisher.Mono;

@Configuration
public class GatewayRoutes {

    private final ObjectMapper objectMapper;
    private final Origins origins;

    public GatewayRoutes(ObjectMapper objectMapper, Origins origins) {
        this.objectMapper = objectMapper;
        this.origins = origins;
    }

    @Bean
    public RouteLocator routes(RouteLocatorBuilder builder) {
        return builder.routes()
                .route("backend", r -> r
                        .path("/api/items/**")
                        .filters(f -> f.rewritePath("/api/items(?<segment>/.*)", "/items${segment}"))
                        .uri(origins.backend()))
                .route("backend-transform", r -> r
                        .path("/api/lookup")
                        .and().method(HttpMethod.POST)
                        .filters(f -> f
                                .rewritePath("/api/lookup", "/items/lookup")
                                .modifyRequestBody(String.class, String.class,
                                        MediaType.APPLICATION_JSON_VALUE,
                                        (exchange, body) -> Mono.justOrEmpty(addField(body, "via", "gateway")))
                                // justOrEmpty, not just: an empty 404 body would otherwise
                                // turn an expected 404 into a gateway 500.
                                .modifyResponseBody(String.class, String.class,
                                        (exchange, body) -> Mono.justOrEmpty(addField(body, "gateway-timestamp",
                                                Instant.now().toString()))))
                        .uri(origins.backend()))
                .route("backend-discovered", r -> r
                        .path("/api/lb/items/**")
                        .filters(f -> f.rewritePath("/api/lb/items(?<segment>/.*)", "/items${segment}"))
                        .uri(origins.discovered()))
                .build();
    }

    /** A non-JSON body (an error page, say) is passed through untouched. */
    private String addField(String body, String field, String value) {
        if (body == null || body.isBlank()) {
            return body;
        }
        try {
            var tree = objectMapper.readTree(body);
            if (!tree.isObject()) {
                return body;
            }
            return objectMapper.writeValueAsString(((ObjectNode) tree).put(field, value));
        } catch (Exception e) {
            return body;
        }
    }
}
