# Prompt: Add native-app callback redirect to moolah-server

## Context

The Moolah native iOS/macOS app (`moolah-native`) authenticates via the server's
existing Google OAuth endpoint (`GET /api/googleauth`), using `ASWebAuthenticationSession`
so the sign-in browser stays inside the app.

The `@hapi/bell` plugin preserves the initial request's query parameters through the
OAuth dance in an encrypted state cookie on the server. After successful authentication,
the Bell handler (`src/handlers/auth/googleLogin.js`) currently always redirects to `/`.

The native app passes `?_native=1` in the initial request:

```
https://moolah.rocks/api/googleauth?_native=1
```

Bell stores this query param in its state cookie. When the handler is called after the
Google OAuth callback, `request.auth.credentials.query` contains `{ _native: '1' }`.

## Required change

**File:** `src/handlers/auth/googleLogin.js`

Modify the redirect at the end of the handler to redirect to `moolah://auth/callback`
when `_native=1` is present, otherwise keep the existing redirect to `/`.

```js
import Boom from '@hapi/boom';

export default {
  auth: {
    strategy: 'google',
    mode: 'try',
  },
  handler: function (request, h) {
    if (!request.auth.isAuthenticated) {
      throw Boom.unauthorized(
        'Authentication failed: ' + request.auth.error.message
      );
    }
    const profile = request.auth.credentials.profile;
    const session = {
      userId: `google-${profile.id}`,
      name: profile.displayName,
      givenName: profile.name.given_name,
      familyName: profile.name.family_name,
      picture: profile.raw.picture,
    };
    request.cookieAuth.set(session);

    // Redirect native app clients to the moolah:// URL scheme so
    // ASWebAuthenticationSession closes automatically without the user
    // having to manually dismiss the browser.
    const query = request.auth.credentials.query ?? {};
    if (query._native) {
      return h.redirect('moolah://auth/callback');
    }
    return h.redirect('/');
  },
};
```

## What this does NOT break

- **Web UI (`moolah/`)**: The web app never adds `?_native=1`, so it continues to
  receive the `/` redirect and the existing web experience is unchanged.
- **Google Cloud Console**: No changes to the registered redirect URI are needed.
  The OAuth callback still goes to `{baseUrl}/api/googleauth` — the native-app
  redirect to `moolah://` happens **after** the OAuth callback, inside the Hapi
  handler. The `moolah://` scheme never appears in the redirect_uri sent to Google.
- **Cookie-based sessions**: The session cookie is set before the redirect in both
  code paths, so subsequent API requests from the native app include the cookie.

## Testing

After applying the change:
1. `GET /api/googleauth` — existing behaviour, redirects to `/` after OAuth ✓
2. `GET /api/googleauth?_native=1` — redirects to `moolah://auth/callback` after OAuth ✓

Verify with a manual curl trace or by running the moolah-server test suite.

## No Google Cloud Console changes required

The registered redirect URI (`https://moolah.rocks/api/googleauth`) is unchanged.
The `moolah://auth/callback` URL is only used for the server→app redirect, not
as a Google OAuth redirect URI.
