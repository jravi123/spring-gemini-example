package com.example.demo.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * Represents a single message turn in a multi-turn conversation.
 */
public record ChatMessage(
		@NotNull(message = "Message role is required") Role role,
		@NotBlank(message = "Message content cannot be blank")
		@Size(max = 10000, message = "Message content must not exceed 10,000 characters") String content) {

	public enum Role {
		USER,
		ASSISTANT
	}
}
