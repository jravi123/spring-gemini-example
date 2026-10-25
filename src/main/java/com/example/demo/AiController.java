package com.example.demo;

import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.example.demo.dto.AiResponse;
import com.example.demo.dto.ChatRequest;
import com.example.demo.dto.TravelPlanRequest;

import jakarta.validation.Valid;

@RestController
@RequestMapping("/ai")
public class AiController {

	private static final Logger logger = LoggerFactory.getLogger(AiController.class);

	private final BackendService backendService;

	public AiController(BackendService backendService) {
		this.backendService = backendService;
	}

	/**
	 * Generates an initial personalized travel plan from structured travel preferences.
	 */
	@PostMapping("/plan")
	public ResponseEntity<AiResponse> generatePlan(@Valid @RequestBody TravelPlanRequest request) {
		logger.info("Generating travel plan for destination: '{}'", request.destination());
		AiResponse response = backendService.generateTravelPlan(request);
		return ResponseEntity.ok(response);
	}

	/**
	 * Handles multi-turn follow-up chat messages with explicit USER and ASSISTANT roles.
	 */
	@PostMapping("/chat")
	public ResponseEntity<AiResponse> chat(@Valid @RequestBody ChatRequest request) {
		logger.info("Processing chat request with {} message(s) in history", request.messages().size());
		AiResponse response = backendService.chat(request.messages());
		return ResponseEntity.ok(response);
	}

	/**
	 * Legacy endpoint retained for backward compatibility.
	 */
	@PostMapping("/generate")
	public String generate(@RequestBody List<String> chatRequest) {
		if (chatRequest == null || chatRequest.isEmpty()) {
			throw new IllegalArgumentException("Chat request list cannot be empty.");
		}
		String userMessage = String.join("\n", chatRequest);
		return backendService.getAiResponse(userMessage);
	}

	@PostMapping("/user")
	public User generate(@RequestBody User user) {
		return backendService.saveUser(user);
	}
}
