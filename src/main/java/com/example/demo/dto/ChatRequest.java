package com.example.demo.dto;

import java.util.List;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Size;

/**
 * Request payload for multi-turn chat interactions with the AI travel agent.
 */
public record ChatRequest(
		@NotEmpty(message = "Conversation messages cannot be empty")
		@Size(max = 50, message = "Conversation history cannot exceed 50 messages")
		List<@Valid ChatMessage> messages) {

	public ChatRequest {
		messages = messages != null ? List.copyOf(messages) : List.of();
	}

	@Override
	public List<ChatMessage> messages() {
		return List.copyOf(this.messages);
	}
}
