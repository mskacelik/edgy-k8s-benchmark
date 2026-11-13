package com.edgy.bench.gateway;

import java.time.Instant;

import org.acme.edgy.runtime.api.Origin;
import org.acme.edgy.runtime.api.Route;
import org.acme.edgy.runtime.api.RoutingConfiguration;
import org.acme.edgy.runtime.builtins.predicates.MethodPredicate;
import org.acme.edgy.runtime.builtins.transformers.requests.RequestJsonObjectBodyModifier;
import org.acme.edgy.runtime.builtins.transformers.responses.ResponseJsonObjectBodyModifier;

import io.vertx.core.http.HttpMethod;
import jakarta.enterprise.inject.Produces;
import jakarta.inject.Singleton;

class EdgyRoutes {

    static final String ORIGIN_PASS_THROUGH = "backend";
    static final String ORIGIN_TRANSFORM = "backend-transform";
    static final String ORIGIN_DISCOVERED = "backend-discovered";

    @Produces
    @Singleton
    RoutingConfiguration routing(Origins origins) {
        return RoutingConfiguration.builder()
                .addRoute(new Route("/api/items/*",
                        Origin.of(ORIGIN_PASS_THROUGH, origins.items())))
                .addRoute(new Route("/api/lookup",
                        Origin.of(ORIGIN_TRANSFORM, origins.lookup()))
                        .setPredicate(new MethodPredicate(HttpMethod.POST))
                        .addRequestTransformer(new RequestJsonObjectBodyModifier(
                                json -> json.put("via", "gateway")))
                        .addResponseTransformer(new ResponseJsonObjectBodyModifier(
                                json -> json.put("gateway-timestamp", Instant.now().toString()))))
                .addRoute(new Route("/api/lb/items/*",
                        Origin.of(ORIGIN_DISCOVERED, origins.discoveredItems())))
                .build();
    }
}
