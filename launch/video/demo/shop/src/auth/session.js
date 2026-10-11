import crypto from 'node:crypto';

const sessions = new Map();

export function createSession(user) {
  const id = crypto.randomUUID();
  sessions.set(id, { user, createdAt: Date.now() });
  return id;
}

export function getSession(id) {
  return sessions.get(id) ?? null;
}
