export async function assertGooglePlayPackageAccess(
  packageName,
  accessToken,
  fetchImpl = fetch,
) {
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${
      encodeURIComponent(packageName)
    }/subscriptions?pageSize=1`;
  const response = await fetchImpl(url, {
    headers: { authorization: `Bearer ${accessToken}` },
  });
  if (!response.ok) {
    const body = await response.text();
    throw new Error(
      `Google Play package access error ${response.status}: ${body}`,
    );
  }
}
