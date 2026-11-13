package com.edgy.bench.gateway;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import jakarta.inject.Singleton;

@Singleton
public class Origins {

    @ConfigProperty(name = "bench.backend.url", defaultValue = "http://localhost:8081")
    String backendUrl;

    @ConfigProperty(name = "bench.backend.service-name", defaultValue = "backend-service")
    String discoveredService;

    public String items() {
        return backendUrl + "/items";
    }

    public String lookup() {
        return backendUrl + "/items/lookup";
    }

    /** Stork over TLS, so the discovered instances are reached on their HTTPS port. */
    public String discoveredItems() {
        return "storks://" + discoveredService + "/items";
    }
}
