#ifndef PythonBridge_h
#define PythonBridge_h

/// Initializes the embedded interpreter (Python-Apple-support b14 layout).
/// `resourcePath` = the app bundle's resource root; the bundled stdlib lives at
/// `<resourcePath>/python` (PYTHONHOME, populated by the install_python build
/// phase), pip packages at `<resourcePath>/app_packages`, and our own module at
/// `<resourcePath>/app`. `caCertPath` = the certifi cacert.pem (embedded Python
/// has no system trust store). Returns 0 on success.
int keraunos_python_init(const char *resourcePath, const char *caCertPath);

/// Calls keraunos_extract.extract(url). Returns a malloc'd UTF-8 JSON string the
/// caller must free(). Returns NULL only on catastrophic bridge failure.
char *keraunos_python_extract(const char *url);

#endif
