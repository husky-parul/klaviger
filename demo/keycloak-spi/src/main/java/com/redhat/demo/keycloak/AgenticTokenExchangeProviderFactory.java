package com.redhat.demo.keycloak;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.protocol.oidc.TokenExchangeProvider;
import org.keycloak.protocol.oidc.TokenExchangeProviderFactory;

/**
 * Factory for AgenticTokenExchangeProvider.
 * Registered with order=200 to take priority over both the built-in standard provider
 * and the act-claim-exchange provider (order=100).
 */
public class AgenticTokenExchangeProviderFactory implements TokenExchangeProviderFactory {

    public static final String PROVIDER_ID = "agentic-token-exchange";

    @Override
    public TokenExchangeProvider create(KeycloakSession session) {
        return new AgenticTokenExchangeProvider(session);
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public int order() {
        return 200;
    }

    @Override
    public void init(Config.Scope config) {
        // no-op
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        // no-op
    }
}
