package com.edgy.bench.scg;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class ScgApplication {

    public static void main(String[] args) {
        // Reactor Netty reads this as a system property only. Set here from the same
        // EVENT_LOOPS variable Edgy uses, so one value drives both gateways.
        String eventLoops = System.getenv().getOrDefault("EVENT_LOOPS", "4");
        System.setProperty("reactor.netty.ioWorkerCount", eventLoops);
        SpringApplication.run(ScgApplication.class, args);
    }
}
