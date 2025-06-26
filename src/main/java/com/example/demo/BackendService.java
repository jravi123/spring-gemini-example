package com.example.demo;

import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.vertexai.gemini.VertexAiGeminiChatModel;
import org.springframework.stereotype.Service;

@Service
public class BackendService {

    private final VertexAiGeminiChatModel chatModel;

    public BackendService(VertexAiGeminiChatModel chatModel) {
        this.chatModel = chatModel;
    }

    @SuppressWarnings("unchecked")
    public String getAiResponse(Map<String, Object> payload) {
        List<Map<String, Object>> contents = (List<Map<String, Object>>) payload.get("contents");
        List<Message> messages = contents.stream()
            .map(entry -> {
                String role = (String) entry.get("role");
                String text = ((List<Map<String, String>>) entry.get("parts")).get(0).get("text");
                if ("user".equalsIgnoreCase(role)) {
                    return new UserMessage(text);
                } else {
                    return new AssistantMessage(text);
                }
            })
            .collect(Collectors.toList());

        ChatResponse response = chatModel.call(new Prompt(messages));
        return response.getResult().getOutput().getText();
    }
}