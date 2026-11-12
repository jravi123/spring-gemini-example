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
		if (messages != null) {
			for (ChatMessage msg : messages) {
				if (msg == null) {
					throw new IllegalArgumentException("Conversation history cannot contain null messages.");
				}
			}
			if (!messages.isEmpty() && messages.get(messages.size() - 1).role() != ChatMessage.Role.USER) {
				throw new IllegalArgumentException("The last message in conversation history must have role USER.");
			}
			messages = List.copyOf(messages);
		} else {
			messages = List.of();
		}
	}

	@Override
	public List<ChatMessage> messages() {
		return List.copyOf(this.messages);
	}
}
