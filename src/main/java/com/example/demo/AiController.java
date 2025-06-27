package com.example.demo;

import java.util.List;

import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class AiController {
	private final BackendService backendService;

	public AiController(BackendService backendService) {
		this.backendService = backendService;
	}

	@PostMapping("/ai/generate")
	public String generate(@RequestBody List<String> chatRequest) {
		String userMessage = String.join("\n",  chatRequest);
		return backendService.getAiResponse(userMessage);
	}
}
