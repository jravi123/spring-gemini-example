package com.example.demo;

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
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.resilience.annotation.EnableResilientMethods;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.servlet.resource.NoResourceFoundException;

import com.example.demo.dto.AiResponse;
import com.example.demo.dto.ChatMessage;
import com.example.demo.dto.ChatRequest;
import com.example.demo.dto.TravelPlanRequest;
import com.example.demo.exception.GlobalExceptionHandler;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class DemoApplicationTests {

	private ChatModel chatModel;
	private UserRepository userRepository;
	private BackendService backendService;
	private MockMvc mockMvc;

	@BeforeEach
	void setUp() {
		chatModel = Mockito.mock(ChatModel.class);
		userRepository = Mockito.mock(UserRepository.class);
		backendService = new BackendService(chatModel, userRepository, "gemini-3.8-flash");

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
	void renderMarkdownToHtmlRendersGfmTables() {
		String markdown = """
				| Day | Activity | Cost |
				| --- | --- | --- |
				| Day 1 | Tokyo Tower | $30 |
				| Day 2 | Mount Fuji | $100 |
				""";
		String html = backendService.renderMarkdownToHtml(markdown);
		assertThat(html).contains("<table>");
		assertThat(html).contains("<thead>");
		assertThat(html).contains("<th>Activity</th>");
		assertThat(html).contains("<td>Tokyo Tower</td>");
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
		assertThat(promptCaptor.getValue().getOptions().getModel()).isEqualTo("gemini-3.8-flash");
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
	void nullModelResponsesAreHandledGracefully() {
		when(chatModel.call(any(Prompt.class))).thenReturn(null);
		AiResponse nullResponse = backendService.generateTravelPlan(new TravelPlanRequest("Tokyo", null, null, null));
		assertThat(nullResponse.markdown()).isEmpty();

		ChatResponse emptyResultResponse = mock(ChatResponse.class);
		when(emptyResultResponse.getResult()).thenReturn(null);
		when(chatModel.call(any(Prompt.class))).thenReturn(emptyResultResponse);
		AiResponse emptyResponse = backendService.generateTravelPlan(new TravelPlanRequest("Tokyo", null, null, null));
		assertThat(emptyResponse.markdown()).isEmpty();
	}

	// =========================================================================
	// Controller Endpoint & Validation Tests
	// =========================================================================

	@Test
	void controllerPlanEndpointReturnsAiResponse() throws Exception {
		Usage usage = mock(Usage.class);
		when(usage.getPromptTokens()).thenReturn(10);
		when(usage.getCompletionTokens()).thenReturn(20);
		when(usage.getTotalTokens()).thenReturn(30);
		ChatResponseMetadata metadata = ChatResponseMetadata.builder().usage(usage).build();

		ChatResponse mockResponse = new ChatResponse(
				List.of(new Generation(new AssistantMessage("Visit the Eiffel Tower."))),
				metadata);
		when(chatModel.call(any(Prompt.class))).thenReturn(mockResponse);

		mockMvc.perform(post("/ai/plan")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "destination": "Paris",
						  "dates": "May 2026",
						  "interests": "Art, Architecture",
						  "budget": "High"
						}
						"""))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.userPrompt").exists())
				.andExpect(jsonPath("$.markdown").value("Visit the Eiffel Tower."))
				.andExpect(jsonPath("$.html").value("<p>Visit the Eiffel Tower.</p>\n"));
	}

	@Test
	void controllerChatEndpointProcessesConversationHistory() throws Exception {
		ChatResponse mockResponse = new ChatResponse(
				List.of(new Generation(new AssistantMessage("Louvre tickets cost around 22 euros."))));
		when(chatModel.call(any(Prompt.class))).thenReturn(mockResponse);

		mockMvc.perform(post("/ai/chat")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "messages": [
						    { "role": "USER", "content": "Tell me about Paris" },
						    { "role": "ASSISTANT", "content": "Paris is known for the Eiffel Tower and Louvre." },
						    { "role": "USER", "content": "How much are Louvre tickets?" }
						  ]
						}
						"""))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.userPrompt").value("How much are Louvre tickets?"))
				.andExpect(jsonPath("$.markdown").value("Louvre tickets cost around 22 euros."))
				.andExpect(jsonPath("$.html").value("<p>Louvre tickets cost around 22 euros.</p>\n"));
	}

	@Test
	void controllerCreateUserEndpointSavesAndReturnsUser() throws Exception {
		User savedUser = new User();
		savedUser.setId(1L);
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
				.andExpect(jsonPath("$.id").value(1))
				.andExpect(jsonPath("$.firstName").value("Jane"))
				.andExpect(jsonPath("$.lastName").value("Doe"));

		ArgumentCaptor<User> userCaptor = ArgumentCaptor.forClass(User.class);
		verify(userRepository).save(userCaptor.capture());
		assertThat(userCaptor.getValue().getFirstName()).isEqualTo("Jane");
		assertThat(userCaptor.getValue().getLastName()).isEqualTo("Doe");
		assertThat(userCaptor.getValue().getId()).isNull();
	}

	@Test
	void controllerGetAllUsersEndpointReturnsSavedUsers() throws Exception {
		User user1 = new User("Jane", "Doe");
		user1.setId(1L);
		User user2 = new User("John", "Smith");
		user2.setId(2L);
		when(userRepository.findAll()).thenReturn(List.of(user1, user2));

		mockMvc.perform(get("/ai/users")
				.accept(MediaType.APPLICATION_JSON))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.length()").value(2))
				.andExpect(jsonPath("$[0].id").value(1))
				.andExpect(jsonPath("$[0].firstName").value("Jane"))
				.andExpect(jsonPath("$[0].lastName").value("Doe"))
				.andExpect(jsonPath("$[1].id").value(2))
				.andExpect(jsonPath("$[1].firstName").value("John"))
				.andExpect(jsonPath("$[1].lastName").value("Smith"));
	}

	@Test
	void controllerCreateUserEndpointRejectsBlankFields() throws Exception {
		mockMvc.perform(post("/ai/user")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "firstName": "   ",
						  "lastName": ""
						}
						"""))
				.andExpect(status().isBadRequest())
				.andExpect(jsonPath("$.title").value("Invalid Request Parameters"));
	}

	@Test
	void controllerCreateUserEndpointRejectsOversizedNames() throws Exception {
		String longName = "A".repeat(101);
		mockMvc.perform(post("/ai/user")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "firstName": "%s",
						  "lastName": "Doe"
						}
						""".formatted(longName)))
				.andExpect(status().isBadRequest())
				.andExpect(jsonPath("$.title").value("Invalid Request Parameters"));
	}

	@Test
	void controllerPlanValidationRejectsOversizedDestination() throws Exception {
		String oversizedDestination = "A".repeat(201);
		mockMvc.perform(post("/ai/plan")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "destination": "%s"
						}
						""".formatted(oversizedDestination)))
				.andExpect(status().isBadRequest())
				.andExpect(jsonPath("$.title").value("Invalid Request Parameters"))
				.andExpect(jsonPath("$.detail").value("destination: Destination must be 200 characters or fewer"));
	}

	@Test
	void controllerChatValidationRejectsBlankMessageContent() throws Exception {
		mockMvc.perform(post("/ai/chat")
				.contentType(MediaType.APPLICATION_JSON)
				.content("""
						{
						  "messages": [
						    { "role": "USER", "content": "   " }
						  ]
						}
						"""))
				.andExpect(status().isBadRequest())
				.andExpect(jsonPath("$.title").value("Invalid Request Parameters"));
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

	@Test
	void globalExceptionHandlerReturns404ForNoResourceFoundException() {
		GlobalExceptionHandler handler = new GlobalExceptionHandler();
		NoResourceFoundException ex = new NoResourceFoundException(HttpMethod.GET, "/nonexistent.ico", "/nonexistent.ico");

		ProblemDetail problem = handler.handleNoResourceFound(ex);
		assertThat(problem.getStatus()).isEqualTo(HttpStatus.NOT_FOUND.value());
		assertThat(problem.getTitle()).isEqualTo("Not Found");
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
	void chatRequestValidatesNonNullAndEnforcesLastRoleIsUser() {
		List<ChatMessage> listWithNull = new ArrayList<>();
		listWithNull.add(null);
		assertThatThrownBy(() -> new ChatRequest(listWithNull))
				.isInstanceOf(IllegalArgumentException.class)
				.hasMessageContaining("cannot contain null messages");

		List<ChatMessage> listEndingWithAssistant = List.of(
				new ChatMessage(ChatMessage.Role.USER, "Hello"),
				new ChatMessage(ChatMessage.Role.ASSISTANT, "Hi there")
		);
		assertThatThrownBy(() -> new ChatRequest(listEndingWithAssistant))
				.isInstanceOf(IllegalArgumentException.class)
				.hasMessageContaining("The last message in conversation history must have role USER");
	}

	@Test
	void demoApplicationCanBeInstantiated() {
		DemoApplication app = new DemoApplication();
		assertThat(app).isNotNull();
	}

	@Test
	void proxiedBackendServiceDoesNotRetryIllegalArgumentException() {
		try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext(ResilienceTestConfig.class)) {
			BackendService proxiedService = ctx.getBean(BackendService.class);
			ChatModel mockChatModel = ctx.getBean(ChatModel.class);

			assertThatThrownBy(() -> proxiedService.chat(List.of()))
					.isInstanceOf(IllegalArgumentException.class)
					.hasMessageContaining("Conversation history cannot be empty");

			when(mockChatModel.call(any(Prompt.class)))
					.thenThrow(new IllegalArgumentException("Invalid model parameter"));

			assertThatThrownBy(() -> proxiedService.chat(List.of(new ChatMessage(ChatMessage.Role.USER, "Hello"))))
					.isInstanceOf(IllegalArgumentException.class)
					.hasMessageContaining("Invalid model parameter");

			verify(mockChatModel, times(1)).call(any(Prompt.class));
		}
	}

	@Configuration(proxyBeanMethods = false)
	@EnableResilientMethods
	static class ResilienceTestConfig {

		@Bean
		ChatModel chatModel() {
			return Mockito.mock(ChatModel.class);
		}

		@Bean
		UserRepository userRepository() {
			return Mockito.mock(UserRepository.class);
		}

		@Bean
		BackendService backendService(ChatModel chatModel, UserRepository userRepository) {
			return new BackendService(chatModel, userRepository);
		}
	}
}
