package com.edgy.bench.scg;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Component
public class Origins {

    private final String backendUrl;
    private final String discoveredService;

    public Origins(@Value("${bench.backend.url:http://localhost:8081}") String backendUrl,
            @Value("${bench.backend.service-name:backend-service}") String discoveredService) {
        this.backendUrl = backendUrl;
        this.discoveredService = discoveredService;
    }

    public String backend() {
        return backendUrl;
    }

    /**
     * Load-balanced over TLS, matching the Edgy gateway's storks:// origin. The
     * scheme prefix is what forces HTTPS on the resolved instance.
     */
    public String discovered() {
        return "lb:https://" + discoveredService;
    }
}
