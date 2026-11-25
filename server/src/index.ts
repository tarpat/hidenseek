import { createApp } from './app';

const app = createApp();
const port = Number(process.env.PORT ?? 8080);
app.listen(port).then(() => console.log(`hidenseek server listening on :${port}`));
