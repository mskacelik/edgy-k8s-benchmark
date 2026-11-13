package com.edgy.bench.backend;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.notNullValue;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import io.restassured.http.ContentType;
import io.vertx.mutiny.pgclient.PgPool;
import jakarta.inject.Inject;

@QuarkusTest
class ItemResourceTest {

    @Inject
    PgPool pool;

    private static final long SEEDED_ID = 1L;
    private static final long UNKNOWN_ID = 999999999L;

    @Test
    void getById_returnsItem() {
        given().get("/items/{id}", SEEDED_ID)
                .then().statusCode(200)
                .body("id", equalTo((int) SEEDED_ID))
                .body("name", notNullValue());
    }

    @Test
    void getById_unknownId_returns404() {
        given().get("/items/{id}", UNKNOWN_ID)
                .then().statusCode(404);
    }

    @Test
    void lookup_returnsItem() {
        given().contentType(ContentType.JSON).body("{\"id\":" + SEEDED_ID + "}")
                .post("/items/lookup")
                .then().statusCode(200)
                .body("id", equalTo((int) SEEDED_ID));
    }

    @Test
    void lookup_ignoresUnknownFields() {
        given().contentType(ContentType.JSON)
                .body("{\"id\":" + SEEDED_ID + ",\"via\":\"gateway\"}")
                .post("/items/lookup")
                .then().statusCode(200)
                .body("id", equalTo((int) SEEDED_ID));
    }

    @Test
    void lookup_unknownId_returns404() {
        given().contentType(ContentType.JSON).body("{\"id\":" + UNKNOWN_ID + "}")
                .post("/items/lookup")
                .then().statusCode(404);
    }

    @Test
    void lookup_missingId_returns400() {
        given().contentType(ContentType.JSON).body("{}")
                .post("/items/lookup")
                .then().statusCode(400);
    }

    @Test
    void lookup_nonNumericId_returns400() {
        given().contentType(ContentType.JSON).body("{\"id\":\"abc\"}")
                .post("/items/lookup")
                .then().statusCode(400);
    }

    @Test
    void lookup_doesNotWrite() {
        long before = count();
        given().contentType(ContentType.JSON).body("{\"id\":" + SEEDED_ID + "}")
                .post("/items/lookup").then().statusCode(200);
        org.junit.jupiter.api.Assertions.assertEquals(before, count());
    }

    /** Straight SQL rather than a test-only endpoint, so the deployed service
     * carries only the two routes the benchmark uses. */
    private long count() {
        return pool.query("SELECT count(*) FROM item").execute()
                .map(rows -> rows.iterator().next().getLong(0))
                .await().indefinitely();
    }
}
