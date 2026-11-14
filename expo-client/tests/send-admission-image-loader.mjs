// Test-only replacement for the native image manipulator; production upload and validation stay real.
export async function resolve(specifier, context, nextResolve) {
  if (specifier.includes('image-variants')) {
    return { url: 'data:text/javascript,export%20async%20function%20jpegVariant()%20%7B%20return%20%22%2F9j%2F2Q%3D%3D%22%3B%20%7D', shortCircuit: true };
  }
  return nextResolve(specifier, context);
}
