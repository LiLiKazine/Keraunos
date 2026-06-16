#import "PythonBridge.h"
#import <Python/Python.h>
#import <string.h>
#import <stdlib.h>

static int gInitialized = 0;

// keraunos_native.eval_js(script: str, timeout_ms: float) -> str
static PyObject *keraunos_native_eval_js(PyObject *self, PyObject *args) {
    const char *script = NULL;
    double timeout_ms = 5000.0;
    if (!PyArg_ParseTuple(args, "s|d", &script, &timeout_ms)) return NULL;
    char *out;
    Py_BEGIN_ALLOW_THREADS
    out = keraunos_js_eval(script, timeout_ms);
    Py_END_ALLOW_THREADS
    PyObject *result = PyUnicode_FromString(out ? out : "__KERAUNOS_JS_ERROR__null");
    if (out) free(out);
    return result;
}

static PyMethodDef keraunos_native_methods[] = {
    {"eval_js", keraunos_native_eval_js, METH_VARARGS, "Evaluate JS via JavaScriptCore; returns console.log output, or a string prefixed __KERAUNOS_JS_ERROR__ on failure."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef keraunos_native_module = {
    PyModuleDef_HEAD_INIT, "keraunos_native", NULL, -1, keraunos_native_methods,
    NULL, NULL, NULL, NULL,
};

static PyObject *PyInit_keraunos_native(void) {
    return PyModule_Create(&keraunos_native_module);
}

// Appends `path` to sys.path. Returns 0 on success.
static int append_sys_path(const char *path) {
    PyObject *sys_path = PySys_GetObject("path");   // borrowed
    if (!sys_path) return -1;
    PyObject *entry = PyUnicode_FromString(path);
    if (!entry) return -1;
    int rc = PyList_Append(sys_path, entry);
    Py_DECREF(entry);
    return rc;
}

int keraunos_python_init(const char *resourcePath, const char *caCertPath) {
    if (gInitialized) return 0;

    // Embedded urllib/ssl have no system trust store; point OpenSSL at the
    // bundled CA bundle before the interpreter starts.
    setenv("SSL_CERT_FILE", caCertPath, 1);

    PyStatus status;
    PyPreConfig preconfig;
    PyConfig config;

    PyImport_AppendInittab("keraunos_native", PyInit_keraunos_native);

    // Pre-initialize in UTF-8 mode (matches the Python-Apple-support testbed).
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) return -1;

    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;     // app bundle is read-only / signed

    // PYTHONHOME = <resources>/python (the install_python build phase copies the
    // stdlib here out of the xcframework). PyConfig_Read derives the stdlib
    // search paths from it.
    char home[PATH_MAX];
    snprintf(home, sizeof(home), "%s/python", resourcePath);
    wchar_t *whome = Py_DecodeLocale(home, NULL);
    if (!whome) { PyConfig_Clear(&config); return -2; }
    status = PyConfig_SetString(&config, &config.home, whome);
    PyMem_RawFree(whome);
    if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return -3; }

    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return -4; }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return -5;

    // Add our vendored packages and our own module dir to sys.path.
    char appPackages[PATH_MAX];
    char app[PATH_MAX];
    snprintf(appPackages, sizeof(appPackages), "%s/app_packages", resourcePath);
    snprintf(app, sizeof(app), "%s/app", resourcePath);
    if (append_sys_path(appPackages) != 0 || append_sys_path(app) != 0) {
        if (PyErr_Occurred()) PyErr_Clear();
        return -6;
    }

    gInitialized = 1;
    return 0;
}

char *keraunos_python_extract(const char *url, const char *cookieFilePath) {
    PyGILState_STATE gil = PyGILState_Ensure();
    char *out = NULL;

    PyObject *module = PyImport_ImportModule("keraunos_extract");
    if (module) {
        PyObject *func = PyObject_GetAttrString(module, "extract");
        if (func && PyCallable_Check(func)) {
            PyObject *args = Py_BuildValue("(s)", url);                 // (url,)
            PyObject *kwargs = PyDict_New();
            if (cookieFilePath && cookieFilePath[0] != '\0') {
                PyObject *cf = PyUnicode_FromString(cookieFilePath);
                if (cf) { PyDict_SetItemString(kwargs, "cookiefile", cf); Py_DECREF(cf); }
            }
            if (args && kwargs) {
                PyObject *result = PyObject_Call(func, args, kwargs);   // extract(url, cookiefile=...)
                if (result) {
                    const char *utf8 = PyUnicode_AsUTF8(result);
                    if (utf8) out = strdup(utf8);
                    Py_DECREF(result);
                }
            }
            Py_XDECREF(args);
            Py_XDECREF(kwargs);
        }
        Py_XDECREF(func);
        Py_DECREF(module);
    }
    if (!out && PyErr_Occurred()) PyErr_Clear();
    PyGILState_Release(gil);

    if (!out) out = strdup("{\"ok\":false,\"error_kind\":\"runtime\",\"detail\":\"python bridge failure\"}");
    return out;
}
