import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

function isProtectedPath(pathname: string): boolean {
  return (
    pathname.startsWith("/platform") ||
    pathname.startsWith("/organization") ||
    pathname.startsWith("/change-password") ||
    pathname.startsWith("/api/admin")
  );
}

export async function proxy(request: NextRequest) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !key) {
    if (isProtectedPath(request.nextUrl.pathname)) {
      return NextResponse.redirect(new URL("/configuration-error", request.url));
    }
    return NextResponse.next();
  }

  let response = NextResponse.next({ request });

  const supabase = createServerClient(url, key, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value);
        }

        response = NextResponse.next({ request });

        for (const { name, value, options } of cookiesToSet) {
          response.cookies.set(name, value, {
            ...options,
            path: "/",
            sameSite: "lax",
            secure: process.env.NODE_ENV === "production",
          });
        }
      },
    },
    cookieOptions: {
      name: "wm-web-auth",
      path: "/",
      sameSite: "lax",
      secure: process.env.NODE_ENV === "production",
    },
  });

  // getClaims verifies the JWT and refreshes an expired access token. Actual
  // route authorization is still performed server-side with auth.getUser()
  // and a fresh RLS-protected profiles query in each protected route.
  await supabase.auth.getClaims();

  if (isProtectedPath(request.nextUrl.pathname)) {
    response.headers.set("Cache-Control", "private, no-store, max-age=0");
    response.headers.set("Vary", "Cookie");
  }

  return response;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|woff2?)$).*)",
  ],
};