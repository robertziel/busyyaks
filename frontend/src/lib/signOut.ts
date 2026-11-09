// The shell's <meta name="sign-out">: the path "Sign out" posts to, or "" when the auth provider has no session to
// end (provider none: every request is the operator). Anything but a same-origin absolute path is refused.
export function signOutTarget(content: string): string | null {
  if (content === "") return null;
  if (!content.startsWith("/") || content.startsWith("//")) throw new Error(`bad <meta name="sign-out">: ${content}`);
  return content;
}
