const workflow = await Deno.readTextFile(
  new URL("../../../.github/workflows/ios-course-ci.yml", import.meta.url),
);
const supabaseConfig = await Deno.readTextFile(
  new URL("../../config.toml", import.meta.url),
);

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("iOS course CI validates the public App Store notification webhook", () => {
  assert(
    workflow.includes("supabase/functions/app-store-notifications/**"),
    "workflow path filter does not include app-store-notifications",
  );
  assert(
    /working-directory:\s*supabase\/functions\/app-store-notifications[\s\S]*?deno fmt --check[\s\S]*?deno lint[\s\S]*?deno check index\.ts[\s\S]*?deno test --allow-read/i
      .test(workflow),
    "workflow does not run the full app-store-notifications Deno gate",
  );
});

Deno.test("Apple can reach the public JWS-authenticated webhook without a Supabase JWT", () => {
  assert(
    /\[functions\.app-store-notifications\]\s+verify_jwt\s*=\s*false/i.test(
      supabaseConfig,
    ),
    "app-store-notifications must disable the gateway JWT check and authenticate Apple's signedPayload in the handler",
  );
});
