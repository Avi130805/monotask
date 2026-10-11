// Batches order emails and flushes them after a short delay.
export function createDigest({ delayMs = 20, send }) {
  let queue = [];
  let timer = null;
  return {
    add(item) {
      queue.push(item);
      if (!timer) {
        timer = setTimeout(() => {
          send(queue);
          queue = [];
          timer = null;
        }, delayMs + Math.random() * 20);
      }
    },
  };
}
