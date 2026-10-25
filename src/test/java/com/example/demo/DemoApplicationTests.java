package com.example.demo;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.Mockito;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.ai.chat.metadata.ChatResponseMetadata;
import org.springframework.ai.chat.metadata.Usage;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.chat.model.Generation;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import com.example.demo.dto.AiResponse;
import com.example.demo.dto.ChatMessage;
import com.example.demo.dto.ChatRequest;
import com.example.demo.dto.TravelPlanRequest;
import com.example.demo.exception.GlobalExceptionHandler;

class DemoApplicationTests {

	private ChatModel chatModel;
	private UserRepository userRepository;
	private BackendService backendService;
	private MockMvc mockMvc;

	@BeforeEach
	void setUp() {
		chatModel = Mockito.mock(ChatModel.class);
		userRepository = Mockito.mock(UserRepository.class);
		backendService = new BackendService(chatModel, userRepository);
		AiController controller = new AiController(backendService);
		mockMvc = MockMvcBuilders.standaloneSetup(controller)
				.setControllerAdvice(new GlobalExceptionHandler())
				.build();
	}

	// =========================================================================
	// BackendService Tests
	// =========================================================================

	@Test
	void generateTravelPlanRendersMarkdownAndEscapesHtml() {
		Usage usage = mock(Usage.class);
		when(usage.getPromptTokens()).thenReturn(15);
		when(usage.getCompletionTokens()).thenReturn(25);
		when(usage.getTotalTokens()).thenReturn(40);
		ChatResponseMetadata metadata = ChatResponseMetadata.builder().usage(usage).build();

		ChatResponse mockResponse = new ChatResponse(
				List.of(new Generation(new AssistantMessage("## Day 1: Kyoto\n- Visit **Fushimi Inari** <script>alert(1)</script>"))),
				metadata);
		when(chatModel.call(any(Prompt.class))).thenReturn(mockResponse);

		TravelPlanRequest request = new TravelPlanRequest("Japan", "2 weeks", "History and food", "Moderate");
		AiResponse result = backendService.generateTravelPlan(request);

		assertThat(result.userPrompt()).contains("Japan", "2 weeks", "History and food", "Moderate");
		assertThat(result.markdown()).contains("## Day 1: Kyoto");
		assertThat(result.html()).contains("<h2>Day 1: Kyoto</h2>");
		assertThat(result.html()).contains("<strong>Fushimi Inari</strong>");
		assertThat(result.html()).doesNotContain("<script>");
	}

	@Test
	void generateTravelPlanAppliesDefaultFallbacksWhenFieldsAreBlank() {
		ChatResponse mockResponse = new ChatResponse(List.of(new Generation(new AssistantMessage("Suggested plan"))));
		when(chatModel.call(any(Prompt.class))).thenReturn(mockResponse);

		TravelPlanRequest blankRequest = new TravelPlanRequest("   ", null, "", null);
		AiResponse result = backendService.generateTravelPlan(blankRequest);

		assertThat(result.userPrompt())
				.contains("Open to suggestions")
				.contains("Flexible")
				.contains("General sightseeing and local culture")
				.contains("Moderate / flexible");
	}

	@Test
	void multiTurnChatPreservesRoleBoundariesAndSkipsBlankMessages() {
		ChatResponse mockResponse = new ChatResponse(List.of(new Generation(new AssistantMessage("Take the Shinkansen bullet train."))));
		when(chatModel.call(any(Prompt.class))).thenReturn(mockResponse);

		List<ChatMessage> history = new ArrayList<>();
		history.add(new ChatMessage(ChatMessage.Role.USER, "Plan a trip to Japan"));
		history.add(null);
		history.add(new ChatMessage(ChatMessage.Role.USER, "   "));
		history.add(new ChatMessage(ChatMessage.Role.ASSISTANT, "Here is your itinerary for Tokyo and Kyoto."));
		history.add(new ChatMessage(ChatMessage.Role.USER, "How should I travel between them?"));

		AiResponse response = backendService.chat(history);
		assertThat(response.markdown()).isEqualTo("Take the Shinkansen bullet train.");

		ArgumentCaptor<Prompt> promptCaptor = ArgumentCaptor.forClass(Prompt.class);
		verify(chatModel).call(promptCaptor.capture());

		List<Message> sentMessages = promptCaptor.getValue().getInstructions();
		assertThat(sentMessages).hasSize(4);
		assertThat(sentMessages.get(0)).isInstanceOf(SystemMessage.class);
		assertThat(sentMessages.get(1)).isInstanceOf(UserMessage.class);
		assertThat(sentMessages.get(2)).isInstanceOf(AssistantMessage.class);
		assertThat(sentMessages.get(3)).isInstanceOf(UserMessage.class);
	}

	@Test
	void chatThrowsIllegalArgumentExceptionWhenHistoryIsNullOrEmpty() {
		assertThatThrownBy(() -> backendService.chat(null))
				.isInstanceOf(IllegalArgumentException.class)
				.hasMessageContaining("Conversation history cannot be empty");

		assertThatThrownBy(() -> backendService.chat(List.of()))
				.isInstanceOf(IllegalArgumentException.class)
				.hasMessageContaining("Conversation history cannot be empty");
	}

	@Test
	void getAiResponseAndNullModelResponsesAreHandledGracefully() {
		when(chatModel.call(any(Prompt.class))).thenReturn(null);
		assertThat(backendService.getAiResponse("Hello")).isEmpty();

		ChatResponse emptyResultResponse = mock(ChatResponse.class);
		when(emptyResultResponse.getResult()).thenReturn(null);
		when(chatModel.call(any(Prompt.class))).thenReturn(emptyResultResponse);
		assertThat(backendService.getAiResponse("Hello")).isEmpty();

		Generation nullOutputGen = mock(Generation.class);
		when(nullOutputGen.getOutput()).thenReturn(null);
		when(emptyResultResponse.getResult()).thenReturn(nullOutputGen);
		assertThat(backendService.getAiResponse("Hello")).isEmpty();
	}

	@Test
	void renderMarkdownToHtmlHandlesBlankAndValidMarkdown() {
		assertThat(backendService.renderMarkdownToHtml(null)).isEmpty();
		assertThat(backendService.renderMarkdownToHtml("   ")).isEmpty();
		assertThat(backendService.renderMarkdownToHtml("**Bold**")).isEqualTo("<p><strong>Bold</strong></p>\n");
	}

	// =========================================================================
	// AiController & GlobalExceptionHandler Tests
	// =========================================================================

	@Test
	void controllerPlanEndpointReturnsStructuredJson() throws Exception {
		ChatResponse mockResponse = new ChatResponse(List.of(new Generation(new AssistantMessage("### Paris Plan"))));
		when(chatModel.call(any(Prompt.class))).thenReturn(mockResponse);

		mockMvc.perform(post("/ai/plan")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "destination": "Paris",
						  "dates": "5 days",
						  "interests": "Museums",
						  "budget": "Mid-range"
						}
						"""))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.markdown").value("### Paris Plan"))
				.andExpect(jsonPath("$.html").value("<h3>Paris Plan</h3>\n"));
	}

	@Test
	void controllerChatEndpointReturnsStructuredJson() throws Exception {
		ChatResponse mockResponse = new ChatResponse(List.of(new Generation(new AssistantMessage("Pack an umbrella!"))));
		when(chatModel.call(any(Prompt.class))).thenReturn(mockResponse);

		mockMvc.perform(post("/ai/chat")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "messages": [
						    { "role": "USER", "content": "What should I pack for London?" }
						  ]
						}
						"""))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.userPrompt").value("What should I pack for London?"))
				.andExpect(jsonPath("$.markdown").value("Pack an umbrella!"))
				.andExpect(jsonPath("$.html").value("<p>Pack an umbrella!</p>\n"));
	}

	@Test
	void controllerGenerateLegacyEndpointReturnsRenderedHtml() throws Exception {
		ChatResponse mockResponse = new ChatResponse(List.of(new Generation(new AssistantMessage("Rome Itinerary"))));
		when(chatModel.call(any(Prompt.class))).thenReturn(mockResponse);

		mockMvc.perform(post("/ai/generate")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						["Destination: Rome", "Duration: 3 days"]
						"""))
				.andExpect(status().isOk())
				.andExpect(content().string("<p>Rome Itinerary</p>\n"));
	}

	@Test
	void controllerGenerateLegacyEndpointRejectsEmptyListWithBadRequest() throws Exception {
		mockMvc.perform(post("/ai/generate")
				.contentType(MediaType.APPLICATION_JSON)
				.content("[]"))
				.andExpect(status().isBadRequest())
				.andExpect(jsonPath("$.title").value("Bad Request"))
				.andExpect(jsonPath("$.detail").value("Chat request list cannot be empty."));
	}

	@Test
	void controllerCreateUserEndpointSavesAndReturnsUser() throws Exception {
		User savedUser = new User();
		savedUser.setFirstName("Jane");
		savedUser.setLastName("Doe");
		when(userRepository.save(any(User.class))).thenReturn(savedUser);

		mockMvc.perform(post("/ai/user")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "firstName": "Jane",
						  "lastName": "Doe"
						}
						"""))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.firstName").value("Jane"))
				.andExpect(jsonPath("$.lastName").value("Doe"));
	}

	@Test
	void controllerChatValidationRejectsEmptyMessages() throws Exception {
		mockMvc.perform(post("/ai/chat")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "messages": []
						}
						"""))
				.andExpect(status().isBadRequest())
				.andExpect(jsonPath("$.title").value("Invalid Request Parameters"));
	}

	@Test
	void globalExceptionHandlerHandlesUnexpectedRuntimeExceptions() throws Exception {
		when(chatModel.call(any(Prompt.class))).thenThrow(new RuntimeException("Vertex AI quota exceeded"));

		mockMvc.perform(post("/ai/plan")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "destination": "Tokyo"
						}
						"""))
				.andExpect(status().isInternalServerError())
				.andExpect(jsonPath("$.title").value("AI Service Error"))
				.andExpect(jsonPath("$.detail").value("Failed to generate a response from the AI service. Please try again shortly."));
	}

	// =========================================================================
	// DTO & Application Initialization Tests
	// =========================================================================

	@Test
	void chatRequestDefensivelyCopiesMessagesList() {
		List<ChatMessage> mutableList = new ArrayList<>();
		mutableList.add(new ChatMessage(ChatMessage.Role.USER, "Hi"));

		ChatRequest chatRequest = new ChatRequest(mutableList);
		mutableList.clear();

		assertThat(chatRequest.messages()).hasSize(1);
		assertThat(new ChatRequest(null).messages()).isEqualTo(Collections.emptyList());
	}

	@Test
	void demoApplicationSetsOtelSystemProperties() {
		DemoApplication app = new DemoApplication();
		assertThat(app).isNotNull();
		assertThat(System.getProperty("otel.sdk.disabled")).isEqualTo("true");
		assertThat(System.getProperty("otel.metrics.exporter")).isEqualTo("none");
		assertThat(System.getProperty("otel.traces.exporter")).isEqualTo("none");
		assertThat(System.getProperty("otel.logs.exporter")).isEqualTo("none");
	}
}
