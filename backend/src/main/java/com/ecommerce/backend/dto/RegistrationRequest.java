package com.ecommerce.backend.dto;

public record RegistrationRequest(
        String email,
        String name,
        String password,
        String passwordConfirm
) {
}
