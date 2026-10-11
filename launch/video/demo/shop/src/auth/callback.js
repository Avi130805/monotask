import { exchangeCode as realExchange } from './google.js';
import { createSession } from './session.js';

export async function handleCallback(url, res, exchangeCode = realExchange) {
  const code = url.searchParams.get('code');
  try {
    const profile = await exchangeCode(code);
    const sid = createSession({ email: profile.email, name: profile.name });
    res.writeHead(302, {
      'set-cookie': `sid=${sid}; HttpOnly; Path=/; SameSite=Lax`,
      location: '/',
    });
    res.end();
  } catch {
    res.writeHead(302, { location: '/?error=signin' });
    res.end();
  }
}
