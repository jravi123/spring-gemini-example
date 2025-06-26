package com.example.demo;

import java.util.stream.Collectors;

import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import com.example.demo.model.ChatRequest;

@RestController
public class AiController {
    private final BackendService backendService;

    public AiController(BackendService backendService) {
        this.backendService = backendService;
    }

    @PostMapping("/ai/generate")
    public String generate(@RequestBody ChatRequest chatRequest) {
        String userMessage = chatRequest.getParts().stream()
                .map(p -> p.getText())
                .collect(Collectors.joining("\n"));
        return backendService.getAiResponse(userMessage, chatRequest.getParts());
    }
}
