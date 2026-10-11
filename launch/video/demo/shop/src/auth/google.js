// Exchanges the OAuth code for a profile. Stubbed in tests.
export async function exchangeCode(code) {
  if (!code) throw new Error('missing code');
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    body: new URLSearchParams({ code, grant_type: 'authorization_code' }),
  });
  const { id_token } = await res.json();
  const [, payload] = id_token.split('.');
  return JSON.parse(Buffer.from(payload, 'base64url').toString());
}
