package com.example.demo;

import org.springframework.ai.vertexai.gemini.VertexAiGeminiChatModel;
import org.springframework.ai.vertexai.gemini.VertexAiGeminiChatOptions;
import org.springframework.ai.vertexai.gemini.VertexAiGeminiChatModel.ChatModel;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration;
import org.springframework.context.annotation.Bean;

import com.google.cloud.vertexai.Transport;
import com.google.cloud.vertexai.VertexAI;

@SpringBootApplication(exclude = {DataSourceAutoConfiguration.class})
public class DemoApplication {

	public static void main(String[] args) {
		SpringApplication.run(DemoApplication.class, args);
	}

	@Bean
	public VertexAiGeminiChatModel vertexAiGeminiChatModel(VertexAI vertexAI) {
		return VertexAiGeminiChatModel.builder()
			.vertexAI(vertexAI)
			.defaultOptions(VertexAiGeminiChatOptions.builder()
				.model(ChatModel.GEMINI_2_5_FLASH)
				.temperature(0.2)
				.topK(5)
				.topP(0.95)
				.build())
			.build();
	}

	@Bean
	public VertexAI vertexAI() {
		return new VertexAI.Builder()
			.setLocation("us-central1")
			.setProjectId("mbcc-test")
			.setTransport(Transport.REST)
			.build();
	}
}
