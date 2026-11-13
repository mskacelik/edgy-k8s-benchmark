package com.edgy.bench.backend;

import io.quarkus.hibernate.reactive.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;

@Entity
public class Item extends PanacheEntityBase {

    // Ids come from the seed, so no generation strategy.
    @Id
    public Long id;

    @Column(nullable = false)
    public String name;

    public String category;

    public int level;

    @Column(columnDefinition = "TEXT")
    public String description;
}
