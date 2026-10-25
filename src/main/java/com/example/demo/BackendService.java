package com.example.demo;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.commonmark.node.Node;
import org.commonmark.parser.Parser;
import org.commonmark.renderer.html.HtmlRenderer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.ai.chat.metadata.Usage;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.chat.model.Generation;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.chat.prompt.PromptTemplate;
import org.springframework.ai.google.genai.GoogleGenAiChatOptions;
import org.springframework.ai.google.genai.common.GoogleGenAiThinkingLevel;
import org.springframework.resilience.annotation.Retryable;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

import com.example.demo.dto.AiResponse;
import com.example.demo.dto.ChatMessage;
import com.example.demo.dto.TravelPlanRequest;

@Service
public class BackendService {

	private static final Logger logger = LoggerFactory.getLogger(BackendService.class);

	private static final String SYSTEM_PROMPT = """
			You are a friendly, expert personal travel agent.
			A user is looking for personalized travel suggestions and itinerary advice.
			Format your response using clean, well-structured Markdown (headings, bullet points, bold text).
			Do NOT wrap the entire response in a ```markdown or ```html code block.
			Keep your tone warm, practical, and engaging.
			""";

	private static final String TRAVEL_PLAN_TEMPLATE = """
			Please create a personalized travel plan based on my preferences:
			- Preferred Destination: {destination}
			- Travel Dates/Duration: {dates}
			- Interests: {interests}
			- Budget: {budget}
			""";

	private final ChatModel chatModel;
	private final UserRepository userRepository;
	private final Parser markdownParser;
	private final HtmlRenderer htmlRenderer;

	public BackendService(ChatModel chatModel, UserRepository userRepository) {
		this.chatModel = chatModel;
		this.userRepository = userRepository;
		this.markdownParser = Parser.builder().build();
		this.htmlRenderer = HtmlRenderer.builder().escapeHtml(true).build();
	}

	public User saveUser(User user) {
		return this.userRepository.save(user);
	}

	/**
	 * Builds a structured initial travel prompt from the user's preferences and calls the AI model.
	 */
	@Retryable(includes = { RuntimeException.class }, maxRetries = 3, delay = 2000, multiplier = 2)
	public AiResponse generateTravelPlan(TravelPlanRequest request) {
		PromptTemplate template = new PromptTemplate(TRAVEL_PLAN_TEMPLATE);
		String userPrompt = template.render(Map.of(
				"destination", defaultIfBlank(request.destination(), "Open to suggestions"),
				"dates", defaultIfBlank(request.dates(), "Flexible"),
				"interests", defaultIfBlank(request.interests(), "General sightseeing and local culture"),
				"budget", defaultIfBlank(request.budget(), "Moderate / flexible")
		)).trim();

		List<ChatMessage> initialConversation = List.of(new ChatMessage(ChatMessage.Role.USER, userPrompt));
		String markdown = callChatWithHistory(initialConversation);
		return new AiResponse(userPrompt, markdown, renderMarkdownToHtml(markdown));
	}

	/**
	 * Conducts a multi-turn conversation using native UserMessage and AssistantMessage role boundaries.
	 */
	@Retryable(includes = { RuntimeException.class }, maxRetries = 3, delay = 2000, multiplier = 2)
	public AiResponse chat(List<ChatMessage> conversationHistory) {
		if (conversationHistory == null || conversationHistory.isEmpty()) {
			throw new IllegalArgumentException("Conversation history cannot be empty.");
		}
		String latestUserMessage = conversationHistory.get(conversationHistory.size() - 1).content();
		String markdown = callChatWithHistory(conversationHistory);
		return new AiResponse(latestUserMessage, markdown, renderMarkdownToHtml(markdown));
	}

	/**
	 * Legacy convenience method for single-string prompt execution.
	 */
	@Retryable(includes = { RuntimeException.class }, maxRetries = 3, delay = 2000, multiplier = 2)
	public String getAiResponse(String userMessage) {
		List<ChatMessage> messages = List.of(new ChatMessage(ChatMessage.Role.USER, userMessage));
		return renderMarkdownToHtml(callChatWithHistory(messages));
	}

	private String callChatWithHistory(List<ChatMessage> conversationHistory) {
		List<Message> messages = new ArrayList<>(conversationHistory.size() + 1);
		messages.add(new SystemMessage(SYSTEM_PROMPT));

		for (ChatMessage msg : conversationHistory) {
			if (msg == null || !StringUtils.hasText(msg.content())) {
				continue;
			}
			if (msg.role() == ChatMessage.Role.ASSISTANT) {
				messages.add(new AssistantMessage(msg.content().trim()));
			} else {
				messages.add(new UserMessage(msg.content().trim()));
			}
		}

		GoogleGenAiChatOptions options = GoogleGenAiChatOptions.builder()
				.thinkingLevel(GoogleGenAiThinkingLevel.LOW)
				.temperature(0.2)
				.build();

		ChatResponse response = this.chatModel.call(new Prompt(messages, options));
		logTokenUsage(response);

		if (response == null) {
			return "";
		}
		Generation result = response.getResult();
		if (result == null) {
			return "";
		}
		AssistantMessage output = result.getOutput();
		if (output == null) {
			return "";
		}
		String text = output.getText();
		return text != null ? text.trim() : "";
	}

	private void logTokenUsage(ChatResponse response) {
		if (response != null && response.getMetadata() != null && response.getMetadata().getUsage() != null) {
			Usage usage = response.getMetadata().getUsage();
			logger.debug("GenAI Token Usage - prompt: {}, completion: {}, total: {}",
					usage.getPromptTokens(), usage.getCompletionTokens(), usage.getTotalTokens());
		}
	}

	public String renderMarkdownToHtml(String markdown) {
		if (!StringUtils.hasText(markdown)) {
			return "";
		}
		Node document = this.markdownParser.parse(markdown);
		return this.htmlRenderer.render(document);
	}

	private static String defaultIfBlank(String value, String fallback) {
		return StringUtils.hasText(value) ? value.trim() : fallback;
	}
}
