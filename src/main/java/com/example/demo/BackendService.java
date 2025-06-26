package com.example.demo;

import java.util.ArrayList;
import java.util.List;
import java.util.stream.Collectors;

import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.vertexai.gemini.VertexAiGeminiChatModel;
import org.springframework.stereotype.Service;

import com.example.demo.model.Part;
import com.vladsch.flexmark.html.HtmlRenderer;
import com.vladsch.flexmark.parser.Parser;
import com.vladsch.flexmark.util.ast.Node;
import com.vladsch.flexmark.util.data.MutableDataSet;

@Service
public class BackendService {

	private final VertexAiGeminiChatModel chatModel;

	private static final String SYSTEM_PROMPT = """
			You are a friendly and knowledgeable personal travel agent.
			A user is looking for travel suggestions.
			Present the information in a clear, engaging, and well-structured format.
			""";

	public BackendService(VertexAiGeminiChatModel chatModel) {
		this.chatModel = chatModel;
	}

	public String getAiResponse(String userMessage, List<Part> conversationHistory) {
		List<Message> messages = new ArrayList<>();
		messages.add(new SystemMessage(SYSTEM_PROMPT));

		// Add previous conversation history
        messages.add(
                new UserMessage(conversationHistory.stream().map(p -> p.getText()).collect(Collectors.joining("\n"))));

        // Add the latest user message
        messages.add(new UserMessage(userMessage));

		ChatResponse response = chatModel.call(new Prompt(messages));
		String markdown = response.getResult().getOutput().getText();

		MutableDataSet options = new MutableDataSet();
		Parser parser = Parser.builder(options).build();
		HtmlRenderer renderer = HtmlRenderer.builder(options).build();
		Node document = parser.parse(markdown);
		return renderer.render(document);
	}
}
