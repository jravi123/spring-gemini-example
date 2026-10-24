package com.example.demo.dto;

/**
 * Structured response from the AI travel agent containing both raw Markdown and rendered safe HTML.
 */
public record AiResponse(
		String userPrompt,
		String markdown,
		String html) {
}
