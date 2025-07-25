package com.example.demo;

import java.util.ArrayList;
import java.util.List;

import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.vertexai.gemini.VertexAiGeminiChatModel;
import org.springframework.stereotype.Service;

@Service
public class BackendService {

	private final VertexAiGeminiChatModel chatModel;

	private static final String SYSTEM_PROMPT = """
			You are a friendly and knowledgeable personal travel agent.
			A user is looking for travel suggestions.
			Present the information in a clear, engaging, and well-structured 
			HTML string that can be inserted into div tag as innerHTML value.
			""";

	public BackendService(VertexAiGeminiChatModel chatModel) {
		this.chatModel = chatModel;
	}

	public String getAiResponse(String userMessage) {
		List<Message> messages = new ArrayList<>();
		messages.add(new SystemMessage(SYSTEM_PROMPT));

		messages.add(new UserMessage(userMessage));

		ChatResponse response = chatModel.call(new Prompt(messages));

		return response.getResult().getOutput().getText();
	}
}
