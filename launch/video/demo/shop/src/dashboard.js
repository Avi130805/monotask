export function renderDashboard(req, res) {
  res.writeHead(200, { 'content-type': 'text/html' });
  res.end('<h1>Your orders</h1>');
}
