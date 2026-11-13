package com.edgy.bench.backend;

import io.quarkus.hibernate.reactive.panache.common.WithSession;
import io.smallrye.mutiny.Uni;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

import org.jboss.resteasy.reactive.RestResponse;

@Path("/items")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class ItemResource {

    @GET
    @Path("/{id}")
    @WithSession
    public Uni<RestResponse<Item>> getById(@PathParam("id") Long id) {
        return find(id);
    }

    /**
     * Reads, never writes. The benchmark's transforming route needs the gateway to
     * buffer a request body without the load generator growing the table.
     */
    @POST
    @Path("/lookup")
    @WithSession
    public Uni<RestResponse<Item>> lookup(LookupRequest request) {
        if (request == null || request.id() == null) {
            return Uni.createFrom().item(RestResponse.status(RestResponse.Status.BAD_REQUEST));
        }
        return find(request.id());
    }

    private Uni<RestResponse<Item>> find(Long id) {
        return Item.<Item> findById(id)
                .map(item -> item == null
                        ? RestResponse.<Item> status(RestResponse.Status.NOT_FOUND)
                        : RestResponse.ok(item));
    }
}
