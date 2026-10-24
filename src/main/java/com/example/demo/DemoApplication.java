package com.example.demo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.resilience.annotation.EnableResilientMethods;

@SpringBootApplication
@EnableResilientMethods
public class DemoApplication {

	static {
		System.setProperty("otel.sdk.disabled", "true");
		System.setProperty("otel.metrics.exporter", "none");
		System.setProperty("otel.traces.exporter", "none");
		System.setProperty("otel.logs.exporter", "none");
		System.setProperty("google.cloud.enable-client-side-metrics", "false");
	}

	public static void main(String[] args) {
		SpringApplication.run(DemoApplication.class, args);
	}

}
