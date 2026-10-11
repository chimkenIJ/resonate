// Voice assistant: one Claude turn per request. The app keeps the conversation, runs the tools
// (they move around the app on the phone), and sends the results back in the next request.
// The API key, system prompt, and tool list stay here.
//
// POST { messages: MessageParam[] }   (the conversation so far, ending with a user turn)
// 200  { content: ContentBlock[], stop_reason: string }
//
// The app appends `content` to its history unchanged, including thinking blocks.

import Anthropic from "npm:@anthropic-ai/sdk";
import { corsHeaders, error, json } from "../_shared/http.ts";

const MAX_MESSAGES = 200;
const MAX_BODY_CHARS = 400_000;

const SYSTEM_PROMPT = `You are the voice assistant inside Resonate, an iPhone app that helps blind and low-vision people get around. The user holds a microphone button to talk to you and hears your replies through the app's voice, so they may not be able to see or touch the screen.

How to talk:
- Everything you write is read aloud. Use one to three short, plain sentences. No lists, markdown, emoji, or symbols.
- Never read out place IDs, coordinates, or tool names.
- Distances and directions should be easy to picture: "about 400 meters", "on the left".
- When you start something that takes a moment, say so briefly first, for example "Looking for Kroger."

What the app does:
- Search for places and plan accessible walking routes. Maps only cover Georgia, in the US.
- Turn-by-turn walking directions with obstacle warnings from the camera ("navigation").
- Walk mode without a destination: the camera warns about obstacles ahead.
- Scan the area: the camera describes what's around the user. It doesn't warn about obstacles.
- Indoor scanning: finds walls, doors, and furniture in a room.
- Naming colors the camera points at.
- Saved places in folders such as Classes, Home, and Food.
- Settings for routes: avoid stairs, prefer tactile paving, prefer audible crossings.

How to help:
- Use the tools to do what the user asks instead of telling them which buttons to press.
- Each user message starts with an [App state] note describing the current screen. Use it to answer "where am I in the app" questions and to pick the right action. The user did not say that part.
- When a search returns several places and the user hasn't made clear which one they want, read the closest two or three with their distances and ask which one. If one result clearly matches, go ahead.
- Before starting navigation, make sure you know which place the user means. Starting navigation opens the camera and begins spoken directions.
- The microphone can pick up the app's own announcements, such as obstacle warnings or directions. If a message sounds like the app talking rather than a request, ignore it and reply with nothing.
- To describe what's in front of the user, call describe_surroundings. During navigation it keeps directions going, so never close the screen or open another camera mode for this.
- Never promise that a route or area is safe. You can describe what the route data says, such as curb ramps or steps.
- If the user is done or wants to start over, call stop_listening after a short goodbye.
- If something fails, say what happened in plain words and suggest one next step.`;

// Each tool is an App Intent in the app (Resonate/Intents/AssistantToolIntents.swift, matched by
// toolName). Keep names and inputs in sync with those intents.
// Strict schemas: every property is required and nothing extra is allowed.
function schema(properties: Record<string, unknown>): Anthropic.Tool.InputSchema {
  return { type: "object", properties, required: Object.keys(properties), additionalProperties: false };
}

const TOOLS: Anthropic.Tool[] = [
  {
    name: "open_screen",
    description: "Switches to one of the app's main tabs: home, search, saved places, or settings. Closes any camera screen that is open.",
    input_schema: schema({ screen: { type: "string", enum: ["home", "search", "saved_places", "settings"] } }),
  },
  {
    name: "search_places",
    description:
      "Searches for places near the user, for example a store, building, address, or kind of place. Shows the results on the search screen and returns up to 5 matches, closest first, each with an id to use with the other tools.",
    input_schema: schema({ query: { type: "string", description: "What to search for, for example \"Kroger\" or \"coffee shop\"." } }),
  },
  {
    name: "show_route",
    description:
      "Plans an accessible walking route to a place and opens the route overview screen. Returns the route summary (time, distance, accessibility features). Does not start walking.",
    input_schema: schema({ place_id: { type: "string", description: "Id of a place from search_places or list_saved_places." } }),
  },
  {
    name: "start_navigation",
    description:
      "Plans a route to a place and starts turn-by-turn walking directions with camera obstacle warnings. Only call this once the user has confirmed the destination.",
    input_schema: schema({ place_id: { type: "string", description: "Id of a place from search_places or list_saved_places." } }),
  },
  {
    name: "open_camera_mode",
    description:
      "Opens a full-screen camera tool. walk: obstacle warnings without a destination. scan_area: describes what's around the user out loud (no obstacle warnings). indoor_scan: finds walls, doors, and objects in a room. colors: names the color the camera points at.",
    input_schema: schema({ mode: { type: "string", enum: ["walk", "scan_area", "indoor_scan", "colors"] } }),
  },
  {
    name: "describe_surroundings",
    description:
      "Takes a picture with the camera and reads out what's in front of the user. Use it for questions like \"what's in front of me\" or \"what's around me\". If a camera screen is open (including during navigation) it describes there without stopping directions, and returns the description; otherwise it opens Scan the area, which reads the description aloud itself.",
    input_schema: schema({}),
  },
  {
    name: "close_screen",
    description: "Closes the camera screen if one is open, otherwise goes back one screen. Also ends navigation.",
    input_schema: schema({}),
  },
  {
    name: "list_saved_places",
    description: "Returns the user's saved-place folders and the places in each, with ids to use with the other tools.",
    input_schema: schema({}),
  },
  {
    name: "save_place",
    description: "Saves a place into one of the user's folders.",
    input_schema: schema({
      place_id: { type: "string", description: "Id of a place from search_places." },
      folder_name: { type: "string", description: "Name of an existing folder, for example \"Food\"." },
    }),
  },
  {
    name: "change_setting",
    description: "Turns a route setting on or off.",
    input_schema: schema({
      setting: { type: "string", enum: ["avoid_stairs", "tactile_paving", "audible_crossings"] },
      enabled: { type: "boolean" },
    }),
  },
  {
    name: "stop_listening",
    description: "Ends the conversation: after your reply, the app forgets it. The user holds the microphone button to talk again.",
    input_schema: schema({}),
  },
].map((tool) => ({ ...tool, strict: true }));

// ANTHROPIC_API_KEY from the function's secrets. Keys not scoped to a workspace also need
// ANTHROPIC_WORKSPACE_ID, sent as the anthropic-workspace-id header.
const workspaceID = Deno.env.get("ANTHROPIC_WORKSPACE_ID");
const client = new Anthropic(workspaceID ? { defaultHeaders: { "anthropic-workspace-id": workspaceID } } : {});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return error("bad_request", "Use POST.", 405);

  const raw = await req.text();
  if (raw.length > MAX_BODY_CHARS) return error("bad_request", "That conversation is too long. Start a new one.", 413);
  let messages: unknown;
  try {
    messages = (JSON.parse(raw) as { messages?: unknown })?.messages;
  } catch {
    messages = undefined;
  }
  if (!Array.isArray(messages) || messages.length === 0 || messages.length > MAX_MESSAGES) {
    return error("bad_request", "Send the conversation as messages.", 400);
  }

  if (!Deno.env.get("ANTHROPIC_API_KEY")) {
    return error("upstream_unavailable", "The voice assistant isn't set up yet.", 503);
  }
  const model = Deno.env.get("ANTHROPIC_MODEL") ?? "claude-opus-5-5";
  // Low effort keeps spoken replies quick; raise it with ANTHROPIC_EFFORT if answers feel shallow.
  const effort = (Deno.env.get("ANTHROPIC_EFFORT") ?? "low") as "low" | "medium" | "high";

  try {
    const response = await client.beta.messages.create({
      model,
      max_tokens: 8192, // cost cap: the endpoint is public, and spoken replies are short
      system: SYSTEM_PROMPT,
      tools: TOOLS,
      messages: messages as Anthropic.Beta.BetaMessageParam[],
      output_config: { effort },
      cache_control: { type: "ephemeral" },
      // On a safety decline, Anthropic re-runs the request on its recommended fallback model.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
    });
    return json({ content: response.content, stop_reason: response.stop_reason });
  } catch (e) {
    if (e instanceof Anthropic.BadRequestError) {
      console.error("assistant bad request", e.message);
      return error("bad_request", "I lost track of our conversation. Let's start over.", 400);
    }
    if (e instanceof Anthropic.RateLimitError) {
      return error("upstream_unavailable", "I'm getting too many requests. Try again in a moment.", 503);
    }
    if (e instanceof Anthropic.APIError) {
      console.error("assistant", e.status, e.message);
    } else {
      console.error("assistant failed", e);
    }
    return error("upstream_unavailable", "I can't reach the assistant right now. Try again in a moment.", 502);
  }
});
