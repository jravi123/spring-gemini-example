package com.example.demo.dto;

import jakarta.validation.constraints.Size;

/**
 * Structured request payload for generating an initial personalized travel plan.
 */
public record TravelPlanRequest(
		@Size(max = 200, message = "Destination must be 200 characters or fewer") String destination,
		@Size(max = 200, message = "Dates/Duration must be 200 characters or fewer") String dates,
		@Size(max = 500, message = "Interests must be 500 characters or fewer") String interests,
		@Size(max = 200, message = "Budget must be 200 characters or fewer") String budget) {
}
