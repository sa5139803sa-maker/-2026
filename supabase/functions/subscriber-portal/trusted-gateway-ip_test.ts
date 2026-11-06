import { assertEquals } from "jsr:@std/assert@1";
import { trustedGatewayIp } from "./trusted-gateway-ip.ts";

Deno.test("uses only the managed gateway client IP header", () => {
  const headers = new Headers({
    "cf-connecting-ip": "203.0.113.7",
    "x-forwarded-for": "198.51.100.99, 203.0.113.8",
    "x-real-ip": "198.51.100.99",
    "x-vercel-forwarded-for": "198.51.100.99",
  });
  assertEquals(trustedGatewayIp(headers), "203.0.113.7");
});

Deno.test("does not trust caller-controlled forwarding headers", () => {
  const headers = new Headers({
    "x-forwarded-for": "198.51.100.99",
    "x-real-ip": "198.51.100.99",
    "x-vercel-forwarded-for": "198.51.100.99",
  });
  assertEquals(trustedGatewayIp(headers), null);
});

Deno.test("fails closed for missing, comma-separated, or malformed header values", () => {
  assertEquals(trustedGatewayIp(new Headers()), null);
  assertEquals(trustedGatewayIp(new Headers({ "cf-connecting-ip": "203.0.113.1, 198.51.100.2" })), null);
  assertEquals(trustedGatewayIp(new Headers({ "cf-connecting-ip": "203.0.113.1\nX-Real-IP: 1.2.3.4" })), null);
});
