package com.edgy.bench.backend;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

/**
 * The gateway adds a field to this body on the way through, so unknown properties
 * must not be an error.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record LookupRequest(Long id) {
}
