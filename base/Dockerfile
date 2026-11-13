# Shared runtime for every JVM image in the benchmark. The JDK, the collector and
# the heap sizing live here and nowhere else, so the two gateways cannot drift apart.
FROM registry.access.redhat.com/ubi9/openjdk-21-runtime:1.24

ENV LANGUAGE='en_US:en'
ENV GC_CONTAINER_OPTIONS="-XX:+UseG1GC"
ENV JAVA_OPTS_APPEND="-XX:MaxRAMPercentage=75.0"

EXPOSE 8080
USER 185

ENTRYPOINT ["/opt/jboss/container/java/run/run-java.sh"]
