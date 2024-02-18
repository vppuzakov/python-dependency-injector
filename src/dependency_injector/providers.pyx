"""Providers module."""

from __future__ import absolute_import

import copy
import errno
import functools
import importlib
import inspect
import json
import os
import re
import sys
import threading
import types
import warnings

try:
    import contextvars
except ImportError:
    contextvars = None

try:
    import builtins
except ImportError:
    # Python 2.7
    import __builtin__ as builtins

try:
    import asyncio
except ImportError:
    asyncio = None
    _is_coroutine_marker = None
else:
    if sys.version_info >= (3, 5, 3):
        import asyncio.coroutines
        _is_coroutine_marker = asyncio.coroutines._is_coroutine
    else:
        _is_coroutine_marker = True

try:
    import ConfigParser as iniconfigparser
except ImportError:
    import configparser as iniconfigparser

try:
    import yaml
except ImportError:
    yaml = None

try:
    import pydantic
    import pydantic_settings
except ImportError:
    pydantic = None

from .errors import (
    Error,
    NoSuchProviderError,
)

cimport cython


if sys.version_info[0] == 3:  # pragma: no cover
    CLASS_TYPES = (type,)
else:  # pragma: no cover
    CLASS_TYPES = (type, types.ClassType)

    copy._deepcopy_dispatch[types.MethodType] = \
        lambda obj, memo: type(obj)(obj.im_func,
                                    copy.deepcopy(obj.im_self, memo),
                                    obj.im_class)

if sys.version_info[:2] == (3, 5):
    warnings.warn(
        "Dependency Injector will drop support of Python 3.5 after Jan 1st of 2022. "
        "This does not mean that there will be any immediate breaking changes, "
        "but tests will no longer be executed on Python 3.5, and bugs will not be addressed.",
        category=DeprecationWarning,
    )

config_env_marker_pattern = re.compile(
    r"\${(?P<name>[^}^{:]+)(?P<separator>:?)(?P<default>.*?)}",
)

def _resolve_config_env_markers(config_content, envs_required=False):
    """Replace environment variable markers with their values."""
    findings = list(config_env_marker_pattern.finditer(config_content))

    for match in reversed(findings):
        env_name = match.group("name")
        has_default = match.group("separator") == ":"

        value = os.getenv(env_name)
        if value is None:
            if not has_default and envs_required:
                raise ValueError(f"Missing required environment variable \"{env_name}\"")
            value = match.group("default")

        span_min, span_max = match.span()
        config_content = f"{config_content[:span_min]}{value}{config_content[span_max:]}"
    return config_content


if sys.version_info[0] == 3:
    def _parse_ini_file(filepath, envs_required=False):
        parser = iniconfigparser.ConfigParser()
        with open(filepath) as config_file:
            config_string = _resolve_config_env_markers(
                config_file.read(),
                envs_required=envs_required,
            )
        parser.read_string(config_string)
        return parser
else:
    import StringIO

    def _parse_ini_file(filepath, envs_required=False):
        parser = iniconfigparser.ConfigParser()
        with open(filepath) as config_file:
            config_string = _resolve_config_env_markers(
                config_file.read(),
                envs_required=envs_required,
            )
        parser.readfp(StringIO.StringIO(config_string))
        return parser


if yaml:
    class YamlLoader(yaml.SafeLoader):
        """YAML loader.

        This loader mimics ``yaml.SafeLoader``.
        """
else:
    class YamlLoader:
        """YAML loader.

        This loader mimics ``yaml.SafeLoader``.
        """


UNDEFINED = object()

cdef int ASYNC_MODE_UNDEFINED = 0
cdef int ASYNC_MODE_ENABLED = 1
cdef int ASYNC_MODE_DISABLED = 2

cdef set __iscoroutine_typecache = set()
cdef tuple __COROUTINE_TYPES = asyncio.coroutines._COROUTINE_TYPES if asyncio else tuple()


cdef class Provider(object):
    """Base provider class.

    :py:class:`Provider` is callable (implements ``__call__`` method). Every
    call to provider object returns provided result, according to the providing
    strategy of particular provider. This ``callable`` functionality is a
    regular part of providers API and it should be the same for all provider
    subclasses.

    Implementation of particular providing strategy should be done in
    :py:meth:`Provider._provide` of :py:class:`Provider` subclass. Current
    method is called every time when not overridden provider is called.

    :py:class:`Provider` implements provider overriding logic that should be
    also common for all providers:

    .. code-block:: python

        provider1 = Factory(SomeClass)
        provider2 = Factory(ChildSomeClass)

        provider1.override(provider2)

        some_instance = provider1()
        assert isinstance(some_instance, ChildSomeClass)

    Also :py:class:`Provider` implements helper function for creating its
    delegates:

    .. code-block:: python

        provider = Factory(object)
        delegate = provider.delegate()

        delegated = delegate()

        assert provider is delegated

    All providers should extend this class.

    .. py:attribute:: overridden
       :noindex:

        Tuple of overriding providers, if any.

        :type: tuple[:py:class:`Provider`] | None
    """

    __IS_PROVIDER__ = True

    overriding_lock = threading.RLock()
    """Overriding reentrant lock.

    :type: :py:class:`threading.RLock`
    """

    def __init__(self):
        """Initializer."""
        self.__overridden = tuple()
        self.__last_overriding = None
        self.__overrides = tuple()
        self.__async_mode = ASYNC_MODE_UNDEFINED
        super(Provider, self).__init__()

    def __call__(self, *args, **kwargs):
        """Return provided object.

        Callable interface implementation.
        """
        if self.__last_overriding is not None:
            result = self.__last_overriding(*args, **kwargs)
        else:
            result = self._provide(args, kwargs)

        if self.__async_mode == ASYNC_MODE_DISABLED:
            return result
        elif self.__async_mode == ASYNC_MODE_ENABLED:
            if __is_future_or_coroutine(result):
                return result
            return __future_result(result)
        elif self.__async_mode == ASYNC_MODE_UNDEFINED:
            if __is_future_or_coroutine(result):
                self.enable_async_mode()
            else:
                self.disable_async_mode()
            return result

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        self._copy_overridings(copied, memo)
        return copied

    @classmethod
    def __class_getitem__(cls, item):
        return cls

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=None)

    def __repr__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return self.__str__()

    @property
    def overridden(self):
        """Return tuple of overriding providers."""
        with self.overriding_lock:
            return self.__overridden

    @property
    def last_overriding(self):
        """Return last overriding provider.

        If provider is not overridden, then None is returned.
        """
        return self.__last_overriding

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        if provider is self:
            raise Error("Provider {0} could not be overridden with itself".format(self))

        if not is_provider(provider):
            provider = Object(provider)

        with self.overriding_lock:
            self.__overridden += (provider,)
            self.__last_overriding = provider
            provider.register_overrides(self)

        return OverridingContext(self, provider)

    def reset_last_overriding(self):
        """Reset last overriding provider.

        :raise: :py:exc:`dependency_injector.errors.Error` if provider is not
                overridden.

        :rtype: None
        """
        with self.overriding_lock:
            if len(self.__overridden) == 0:
                raise Error("Provider {0} is not overridden".format(str(self)))

            self.__last_overriding.unregister_overrides(self)

            self.__overridden = self.__overridden[:-1]
            try:
                self.__last_overriding = self.__overridden[-1]
            except IndexError:
                self.__last_overriding = None

    def reset_override(self):
        """Reset all overriding providers.

        :rtype: None
        """
        with self.overriding_lock:
            for provider in self.__overridden:
                provider.unregister_overrides(self)
            self.__overridden = tuple()
            self.__last_overriding = None

    @property
    def overrides(self):
        """Return providers that are overridden by the current provider."""
        return self.__overrides

    def register_overrides(self, provider):
        """Register provider that overrides current provider."""
        self.__overrides =  tuple(set(self.__overrides + (provider,)))

    def unregister_overrides(self, provider):
        """Unregister provider that overrides current provider."""
        overrides = set(self.__overrides)
        if provider in overrides:
            overrides.remove(provider)
        self.__overrides = tuple(overrides)

    def async_(self, *args, **kwargs):
        """Return provided object asynchronously.

        This method is a synonym of __call__().
        It provides typing stubs for correct type checking with
        `await` expression:

        .. code-block:: python

            database_provider: Provider[DatabaseConnection] = Resource(init_db_async)

            async def main():
                db: DatabaseConnection = await database_provider.async_()
                ...
        """
        return self.__call__(*args, **kwargs)

    def delegate(self):
        """Return provider delegate.

        :rtype: :py:class:`Delegate`
        """
        warnings.warn(
            "Method \".delegate()\" is deprecated since version 4.0.0. "
            "Use \".provider\" attribute instead.",
            category=DeprecationWarning,
        )
        return Delegate(self)

    @property
    def provider(self):
        """Return provider"s delegate.

        :rtype: :py:class:`Delegate`
        """
        return Delegate(self)

    @property
    def provided(self):
        """Return :py:class:`ProvidedInstance` provider."""
        return ProvidedInstance(self)

    def enable_async_mode(self):
        """Enable async mode."""
        self.__async_mode = ASYNC_MODE_ENABLED

    def disable_async_mode(self):
        """Disable async mode."""
        self.__async_mode = ASYNC_MODE_DISABLED

    def reset_async_mode(self):
        """Reset async mode.

        Provider will automatically set the mode on the next call.
        """
        self.__async_mode = ASYNC_MODE_UNDEFINED

    cpdef bint is_async_mode_enabled(self):
        """Check if async mode is enabled."""
        return self.__async_mode == ASYNC_MODE_ENABLED

    cpdef bint is_async_mode_disabled(self):
        """Check if async mode is disabled."""
        return self.__async_mode == ASYNC_MODE_DISABLED

    cpdef bint is_async_mode_undefined(self):
        """Check if async mode is undefined."""
        return self.__async_mode == ASYNC_MODE_UNDEFINED

    @property
    def related(self):
        """Return related providers generator."""
        yield from self.overridden

    def traverse(self, types=None):
        """Return providers traversal generator."""
        return traverse(*self.related, types=types)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Providing strategy implementation.

        Abstract protected method that implements providing strategy of
        particular provider. Current method is called every time when not
        overridden provider is called. Need to be overridden in subclasses.
        """
        raise NotImplementedError()

    cpdef void _copy_overridings(self, Provider copied, dict memo):
        """Copy provider overridings to a newly copied provider."""
        copied.__overridden = deepcopy(self.__overridden, memo)
        copied.__last_overriding = deepcopy(self.__last_overriding, memo)
        copied.__overrides = deepcopy(self.__overrides, memo)


cdef class Object(Provider):
    """Object provider returns provided instance "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, provides=None):
        """Initialize provider."""
        self.__provides = None
        self.set_provides(provides)
        super(Object, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_provides(self.provides)

        self._copy_overridings(copied, memo)

        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.__provides)

    def __repr__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return self.__str__()

    @property
    def provides(self):
        """Return provider provides."""
        return self.__provides

    def set_provides(self, provides):
        """Set provider provides."""
        self.__provides = provides
        return self

    @property
    def related(self):
        """Return related providers generator."""
        if isinstance(self.__provides, Provider):
            yield self.__provides
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return provided instance.

        :param args: Tuple of context positional arguments.
        :type args: tuple[object]

        :param kwargs: Dictionary of context keyword arguments.
        :type kwargs: dict[str, object]

        :rtype: object
        """
        return self.__provides


cdef class Self(Provider):
    """Self provider returns own container."""

    def __init__(self, container=None):
        """Initialize provider."""
        self.__container = container
        self.__alt_names = tuple()
        super().__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_container(deepcopy(self.__container, memo))
        copied.set_alt_names(self.__alt_names)
        self._copy_overridings(copied, memo)
        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.__container)

    def __repr__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return self.__str__()

    def set_container(self, container):
        self.__container = container

    def set_alt_names(self, alt_names):
        self.__alt_names = tuple(set(alt_names))

    @property
    def alt_names(self):
        return self.__alt_names

    cpdef object _provide(self, tuple args, dict kwargs):
        return self.__container


cdef class Delegate(Provider):
    """Delegate provider returns provider "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, provides=None):
        """Initialize provider."""
        self.__provides = None
        self.set_provides(provides)
        super(Delegate, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_provides(_copy_if_provider(self.provides, memo))
        self._copy_overridings(copied, memo)

        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.__provides)

    def __repr__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return self.__str__()

    @property
    def provides(self):
        """Return provider provides."""
        return self.__provides

    def set_provides(self, provides):
        """Set provider provides."""
        if provides:
            provides = ensure_is_provider(provides)
        self.__provides = provides
        return self

    @property
    def related(self):
        """Return related providers generator."""
        yield self.__provides
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return provided instance.

        :param args: Tuple of context positional arguments.
        :type args: tuple[object]

        :param kwargs: Dictionary of context keyword arguments.
        :type kwargs: dict[str, object]

        :rtype: object
        """
        return self.__provides


cdef class Aggregate(Provider):
    """Providers aggregate.

    :py:class:`Aggregate` is a delegated provider, meaning that it is
    injected "as is".

    All aggregated providers can be retrieved as a read-only
    dictionary :py:attr:`Aggregate.providers` or as an attribute of
    :py:class:`Aggregate`, e.g. ``aggregate.provider``.
    """

    __IS_DELEGATED__ = True

    def __init__(self, provider_dict=None, **provider_kwargs):
        """Initialize provider."""
        self.__providers = {}
        self.set_providers(provider_dict, **provider_kwargs)
        super().__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_providers(deepcopy(self.providers, memo))

        self._copy_overridings(copied, memo)

        return copied

    def __getattr__(self, factory_name):
        """Return aggregated provider."""
        return self.__get_provider(factory_name)

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.providers)

    @property
    def providers(self):
        """Return dictionary of providers, read-only.

        Alias for ``.factories`` attribute.
        """
        return dict(self.__providers)

    def set_providers(self, provider_dict=None, **provider_kwargs):
        """Set providers.

        Alias for ``.set_factories()`` method.
        """
        providers = {}
        providers.update(provider_kwargs)
        if provider_dict:
            providers.update(provider_dict)

        for provider in providers.values():
            if not is_provider(provider):
                raise Error(
                    "{0} can aggregate only instances of {1}, given - {2}".format(
                        self.__class__,
                        Provider,
                        provider,
                    ),
                )

        self.__providers = providers
        return self

    def override(self, _):
        """Override provider with another provider.

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        raise Error("{0} providers could not be overridden".format(self.__class__))

    @property
    def related(self):
        """Return related providers generator."""
        yield from self.__providers.values()
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        try:
            provider_name = args[0]
        except IndexError:
            try:
                provider_name = kwargs.pop("factory_name")
            except KeyError:
                raise TypeError("Missing 1st required positional argument: \"provider_name\"")
        else:
            args = args[1:]

        return self.__get_provider(provider_name)(*args, **kwargs)

    cdef Provider __get_provider(self, object provider_name):
        if provider_name not in self.__providers:
            raise NoSuchProviderError("{0} does not contain provider with name {1}".format(self, provider_name))
        return <Provider> self.__providers[provider_name]


cdef class Dependency(Provider):
    """:py:class:`Dependency` provider describes dependency interface.

    This provider is used for description of dependency interface. That might
    be useful when dependency could be provided in the client"s code only,
    but its interface is known. Such situations could happen when required
    dependency has non-deterministic list of dependencies itself.

    .. code-block:: python

        database_provider = Dependency(sqlite3.dbapi2.Connection)
        database_provider.override(Factory(sqlite3.connect, ":memory:"))

        database = database_provider()

    .. py:attribute:: instance_of
       :noindex:

        Class of required dependency.

        :type: type
   """

    def __init__(self, object instance_of=object, default=None):
        """Initialize provider."""
        self.__instance_of = None
        self.set_instance_of(instance_of)

        self.__default = None
        self.set_default(default)

        self.__parent = None

        super(Dependency, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_instance_of(self.instance_of)
        copied.set_default(deepcopy(self.default, memo))

        self._copy_parent(copied, memo)
        self._copy_overridings(copied, memo)

        return copied

    def __call__(self, *args, **kwargs):
        """Return provided instance.

        :raise: :py:exc:`dependency_injector.errors.Error`

        :rtype: object
        """
        if self.__last_overriding:
            result = self.__last_overriding(*args, **kwargs)
        elif self.__default:
            result = self.__default(*args, **kwargs)
        else:
            self._raise_undefined_error()

        if self.__async_mode == ASYNC_MODE_DISABLED:
            self._check_instance_type(result)
            return result
        elif self.__async_mode == ASYNC_MODE_ENABLED:
            if __is_future_or_coroutine(result):
                future_result = asyncio.Future()
                result = asyncio.ensure_future(result)
                result.add_done_callback(functools.partial(self._async_provide, future_result))
                return future_result
            else:
                self._check_instance_type(result)
                return __future_result(result)
        elif self.__async_mode == ASYNC_MODE_UNDEFINED:
            if __is_future_or_coroutine(result):
                self.enable_async_mode()

                future_result = asyncio.Future()
                result = asyncio.ensure_future(result)
                result.add_done_callback(functools.partial(self._async_provide, future_result))
                return future_result
            else:
                self.disable_async_mode()
                self._check_instance_type(result)
                return result

    def __getattr__(self, name):
        if self.__last_overriding:
            return getattr(self.__last_overriding, name)
        elif self.__default:
            return getattr(self.__default, name)
        raise AttributeError(f"Provider \"{self.__class__.__name__}\" has no attribute \"{name}\"")

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        name = f"<{self.__class__.__module__}.{self.__class__.__name__}"
        name += f"({repr(self.__instance_of)}) at {hex(id(self))}"
        if self.parent_name:
            name += f", container name: \"{self.parent_name}\""
        name += f">"
        return name

    def __repr__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return self.__str__()

    @property
    def instance_of(self):
        """Return type."""
        return self.__instance_of

    def set_instance_of(self, instance_of):
        """Set type."""
        if not isinstance(instance_of, CLASS_TYPES):
            raise TypeError(
                "\"instance_of\" has incorrect type (expected {0}, got {1}))".format(
                    CLASS_TYPES,
                    instance_of,
                ),
            )
        self.__instance_of = instance_of
        return self

    @property
    def default(self):
        """Return default provider."""
        return self.__default

    def set_default(self, default):
        """Set type."""
        if default is not None and not isinstance(default, Provider):
            default = Object(default)
        self.__default = default
        return self

    @property
    def is_defined(self):
        """Return True if dependency is defined."""
        return self.__last_overriding is not None or self.__default is not None

    def provided_by(self, provider):
        """Set external dependency provider.

        :param provider: Provider that provides required dependency.
        :type provider: :py:class:`Provider`

        :rtype: None
        """
        return self.override(provider)

    @property
    def related(self):
        """Return related providers generator."""
        if self.__default:
            yield self.__default
        yield from super().related

    @property
    def parent(self):
        """Return parent."""
        return self.__parent

    @property
    def parent_name(self):
        """Return parent name."""
        if not self.__parent:
            return None

        name = ""
        if self.__parent.parent_name:
            name += f"{self.__parent.parent_name}."
        name += f"{self.__parent.resolve_provider_name(self)}"

        return name

    def assign_parent(self, parent):
        """Assign parent."""
        self.__parent = parent

    def _copy_parent(self, copied, memo):
        _copy_parent(self, copied, memo)

    def _async_provide(self, future_result, future):
        try:
            instance = future.result()
            self._check_instance_type(instance)
        except Exception as exception:
            future_result.set_exception(exception)
        else:
            future_result.set_result(instance)

    def _check_instance_type(self, instance):
        if not isinstance(instance, self.instance_of):
            raise Error("{0} is not an instance of {1}".format(instance, self.instance_of))

    def _raise_undefined_error(self):
        if self.parent_name:
            raise Error(f"Dependency \"{self.parent_name}\" is not defined")
        raise Error("Dependency is not defined")


cdef class ExternalDependency(Dependency):
    """:py:class:`ExternalDependency` provider describes dependency interface.

    This provider is used for description of dependency interface. That might
    be useful when dependency could be provided in the client code only,
    but its interface is known. Such situations could happen when required
    dependency has non-deterministic list of dependencies itself.

    .. code-block:: python

        database_provider = ExternalDependency(sqlite3.dbapi2.Connection)
        database_provider.override(Factory(sqlite3.connect, ":memory:"))

        database = database_provider()

    .. deprecated:: 3.9

        Use :py:class:`Dependency` instead.

    .. py:attribute:: instance_of
       :noindex:

        Class of required dependency.

        :type: type
    """


cdef class DependenciesContainer(Object):
    """:py:class:`DependenciesContainer` provider provides set of dependencies.


    Dependencies container provider is used to implement late static binding
    for a set of providers of a particular container.

    Example code:

    .. code-block:: python

        class Adapters(containers.DeclarativeContainer):
            email_sender = providers.Singleton(SmtpEmailSender)

        class TestAdapters(containers.DeclarativeContainer):
            email_sender = providers.Singleton(EchoEmailSender)

        class UseCases(containers.DeclarativeContainer):
            adapters = providers.DependenciesContainer()

            signup = providers.Factory(SignupUseCase,
                                       email_sender=adapters.email_sender)

        use_cases = UseCases(adapters=Adapters)
        # or
        use_cases = UseCases(adapters=TestAdapters)

        # Another file
        from .containers import use_cases

        use_case = use_cases.signup()
        use_case.execute()
    """

    def __init__(self, **dependencies):
        """Initializer."""
        for provider in dependencies.values():
            if isinstance(provider, CHILD_PROVIDERS):
                provider.assign_parent(self)

        self.__providers = dependencies
        self.__parent = None

        super(DependenciesContainer, self).__init__(None)

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        cdef DependenciesContainer copied

        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = <DependenciesContainer> _memorized_duplicate(self, memo)
        copied.__provides = deepcopy(self.__provides, memo)
        copied.__providers = deepcopy(self.__providers, memo)
        self._copy_parent(copied, memo)
        self._copy_overridings(copied, memo)

        return copied

    def __getattr__(self, name):
        """Return dependency provider."""
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(
                "'{cls}' object has no attribute "
                "'{attribute_name}'".format(cls=self.__class__.__name__, attribute_name=name)
            )

        provider = self.__providers.get(name)
        if not provider:
            provider = Dependency()
            provider.assign_parent(self)

            self.__providers[name] = provider

            container = self.__call__()
            if container:
                dependency_provider = container.providers.get(name)
                if dependency_provider:
                    provider.override(dependency_provider)

        return provider

    @property
    def providers(self):
        """Read-only dictionary of dependency providers."""
        return self.__providers

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        self._override_providers(container=provider)
        return super(DependenciesContainer, self).override(provider)

    def reset_last_overriding(self):
        """Reset last overriding provider.

        :raise: :py:exc:`dependency_injector.errors.Error` if provider is not
                overridden.

        :rtype: None
        """
        for child in self.__providers.values():
            try:
                child.reset_last_overriding()
            except Error:
                pass
        super(DependenciesContainer, self).reset_last_overriding()

    def reset_override(self):
        """Reset all overriding providers.

        :rtype: None
        """
        for child in self.__providers.values():
            child.reset_override()
        super(DependenciesContainer, self).reset_override()

    @property
    def related(self):
        """Return related providers generator."""
        yield from self.providers.values()
        yield from super().related

    def resolve_provider_name(self, provider):
        """Try to resolve provider name."""
        for provider_name, container_provider in self.providers.items():
            if container_provider is provider:
                return provider_name
        else:
            raise Error(f"Can not resolve name for provider \"{provider}\"")

    @property
    def parent(self):
        """Return parent."""
        return self.__parent

    @property
    def parent_name(self):
        """Return parent name."""
        if not self.__parent:
            return None

        name = ""
        if self.__parent.parent_name:
            name += f"{self.__parent.parent_name}."
        name += f"{self.__parent.resolve_provider_name(self)}"

        return name

    def assign_parent(self, parent):
        """Assign parent."""
        self.__parent = parent

    def _copy_parent(self, copied, memo):
        _copy_parent(self, copied, memo)

    cpdef object _override_providers(self, object container):
        """Override providers with providers from provided container."""
        for name, dependency_provider in container.providers.items():
            provider = getattr(self, name)

            if provider.last_overriding is dependency_provider:
                continue

            provider.override(dependency_provider)


cdef class Callable(Provider):
    r"""Callable provider calls wrapped callable on every call.

    Callable supports positional and keyword argument injections:

    .. code-block:: python

        some_function = Callable(some_function,
                                 "positional_arg1", "positional_arg2",
                                 keyword_argument1=3, keyword_argument=4)

        # or

        some_function = Callable(some_function) \
            .add_args("positional_arg1", "positional_arg2") \
            .add_kwargs(keyword_argument1=3, keyword_argument=4)

        # or

        some_function = Callable(some_function)
        some_function.add_args("positional_arg1", "positional_arg2")
        some_function.add_kwargs(keyword_argument1=3, keyword_argument=4)
    """

    def __init__(self, provides=None, *args, **kwargs):
        """Initialize provider."""
        self.__provides = None
        self.set_provides(provides)

        self.__args = tuple()
        self.__args_len = 0
        self.set_args(*args)

        self.__kwargs = tuple()
        self.__kwargs_len = 0
        self.set_kwargs(**kwargs)

        super(Callable, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_provides(_copy_if_provider(self.provides, memo))
        copied.set_args(*deepcopy(self.args, memo))
        copied.set_kwargs(**deepcopy(self.kwargs, memo))
        self._copy_overridings(copied, memo)
        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.__provides)

    @property
    def provides(self):
        """Return provider provides."""
        return self.__provides

    def set_provides(self, provides):
        """Set provider provides."""
        provides = _resolve_string_import(provides)
        if provides and not callable(provides):
            raise Error(
                "Provider {0} expected to get callable, got {1} instead".format(
                    _class_qualname(self),
                    provides,
                ),
            )
        self.__provides = provides
        return self

    @property
    def args(self):
        """Return positional argument injections."""
        cdef int index
        cdef PositionalInjection arg
        cdef list args

        args = list()
        for index in range(self.__args_len):
            arg = self.__args[index]
            args.append(arg.__value)
        return tuple(args)

    def add_args(self, *args):
        """Add positional argument injections.

        :return: Reference ``self``
        """
        self.__args += parse_positional_injections(args)
        self.__args_len = len(self.__args)
        return self

    def set_args(self, *args):
        """Set positional argument injections.

        Existing positional argument injections are dropped.

        :return: Reference ``self``
        """
        self.__args = parse_positional_injections(args)
        self.__args_len = len(self.__args)
        return self

    def clear_args(self):
        """Drop positional argument injections.

        :return: Reference ``self``
        """
        self.__args = tuple()
        self.__args_len = len(self.__args)
        return self

    @property
    def kwargs(self):
        """Return keyword argument injections."""
        cdef int index
        cdef NamedInjection kwarg
        cdef dict kwargs

        kwargs = dict()
        for index in range(self.__kwargs_len):
            kwarg = self.__kwargs[index]
            kwargs[kwarg.__name] = kwarg.__value
        return kwargs

    def add_kwargs(self, **kwargs):
        """Add keyword argument injections.

        :return: Reference ``self``
        """
        self.__kwargs += parse_named_injections(kwargs)
        self.__kwargs_len = len(self.__kwargs)
        return self

    def set_kwargs(self, **kwargs):
        """Set keyword argument injections.

        Existing keyword argument injections are dropped.

        :return: Reference ``self``
        """
        self.__kwargs = parse_named_injections(kwargs)
        self.__kwargs_len = len(self.__kwargs)
        return self

    def clear_kwargs(self):
        """Drop keyword argument injections.

        :return: Reference ``self``
        """
        self.__kwargs = tuple()
        self.__kwargs_len = len(self.__kwargs)
        return self

    @property
    def related(self):
        """Return related providers generator."""
        yield from filter(is_provider, [self.provides])
        yield from filter(is_provider, self.args)
        yield from filter(is_provider, self.kwargs.values())
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return result of provided callable call."""
        return __callable_call(self, args, kwargs)


cdef class DelegatedCallable(Callable):
    """Callable that is injected "as is".

    DelegatedCallable is a :py:class:`Callable`, that is injected "as is".
    """

    __IS_DELEGATED__ = True


cdef class AbstractCallable(Callable):
    """Abstract callable provider.

    :py:class:`AbstractCallable` is a :py:class:`Callable` provider that must
    be explicitly overridden before calling.

    Overriding of :py:class:`AbstractCallable` is possible only by another
    :py:class:`Callable` provider.
    """

    def __call__(self, *args, **kwargs):
        """Return provided object.

        Callable interface implementation.
        """
        if self.__last_overriding is None:
            raise Error("{0} must be overridden before calling".format(self))
        return super().__call__(*args, **kwargs)

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        if not isinstance(provider, Callable):
            raise Error("{0} must be overridden only by "
                        "{1} providers".format(self, Callable))
        return super(AbstractCallable, self).override(provider)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return result of provided callable"s call."""
        raise NotImplementedError("Abstract provider forward providing logic "
                                  "to overriding provider")


cdef class CallableDelegate(Delegate):
    """Callable delegate injects delegating callable "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, callable):
        """Initializer.

        :param callable: Value that have to be provided.
        :type callable: object
        """
        if isinstance(callable, Callable) is False:
            raise Error("{0} can wrap only {1} providers".format(self.__class__, Callable))
        super(CallableDelegate, self).__init__(callable)


cdef class Coroutine(Callable):
    r"""Coroutine provider creates wrapped coroutine on every call.

    Coroutine supports positional and keyword argument injections:

    .. code-block:: python

        some_coroutine = Coroutine(some_coroutine,
                                   "positional_arg1", "positional_arg2",
                                   keyword_argument1=3, keyword_argument=4)

        # or

        some_coroutine = Coroutine(some_coroutine) \
            .add_args("positional_arg1", "positional_arg2") \
            .add_kwargs(keyword_argument1=3, keyword_argument=4)

        # or

        some_coroutine = Coroutine(some_coroutine)
        some_coroutine.add_args("positional_arg1", "positional_arg2")
        some_coroutine.add_kwargs(keyword_argument1=3, keyword_argument=4)
    """

    _is_coroutine = _is_coroutine_marker

    def set_provides(self, provides):
        """Set provider provides."""
        if not asyncio:
            raise Error("Package asyncio is not available")
        provides = _resolve_string_import(provides)
        if provides and not asyncio.iscoroutinefunction(provides):
            raise Error(f"Provider {_class_qualname(self)} expected to get coroutine function, "
                        f"got {provides} instead")
        return super().set_provides(provides)


cdef class DelegatedCoroutine(Coroutine):
    """Coroutine provider that is injected "as is".

    DelegatedCoroutine is a :py:class:`Coroutine`, that is injected "as is".
    """

    __IS_DELEGATED__ = True


cdef class AbstractCoroutine(Coroutine):
    """Abstract coroutine provider.

    :py:class:`AbstractCoroutine` is a :py:class:`Coroutine` provider that must
    be explicitly overridden before calling.

    Overriding of :py:class:`AbstractCoroutine` is possible only by another
    :py:class:`Coroutine` provider.
    """

    def __call__(self, *args, **kwargs):
        """Return provided object.

        Callable interface implementation.
        """
        if self.__last_overriding is None:
            raise Error("{0} must be overridden before calling".format(self))
        return super().__call__(*args, **kwargs)

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        if not isinstance(provider, Coroutine):
            raise Error("{0} must be overridden only by "
                        "{1} providers".format(self, Coroutine))
        return super(AbstractCoroutine, self).override(provider)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return result of provided callable"s call."""
        raise NotImplementedError("Abstract provider forward providing logic "
                                  "to overriding provider")


cdef class CoroutineDelegate(Delegate):
    """Coroutine delegate injects delegating coroutine "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, coroutine):
        """Initializer.

        :param coroutine: Value that have to be provided.
        :type coroutine: object
        """
        if isinstance(coroutine, Coroutine) is False:
            raise Error("{0} can wrap only {1} providers".format(self.__class__, Callable))
        super(CoroutineDelegate, self).__init__(coroutine)


cdef class ConfigurationOption(Provider):
    """Child configuration option provider.

    This provider should not be used directly. It is a part of the
    :py:class:`Configuration` provider.
    """

    def __init__(self, name=None, Configuration root=None, required=False):
        self.__name = name
        self.__root = root
        self.__children = {}
        self.__required = required
        self.__cache = UNDEFINED
        super().__init__()

    def __deepcopy__(self, memo):
        cdef ConfigurationOption copied

        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = <ConfigurationOption> _memorized_duplicate(self, memo)
        copied.__name = deepcopy(self.__name, memo)
        copied.__root = deepcopy(self.__root, memo)
        copied.__children = deepcopy(self.__children, memo)
        copied.__required = self.__required
        self._copy_overridings(copied, memo)
        return copied

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        pass

    def __str__(self):
        return represent_provider(provider=self, provides=self.get_name())

    def __getattr__(self, item):
        if item.startswith("__") and item.endswith("__"):
            raise AttributeError(
                "'{cls}' object has no attribute "
                "'{attribute_name}'".format(cls=self.__class__.__name__, attribute_name=item)
            )

        child = self.__children.get(item)
        if child is None:
            child_name = self.__name + (item,)
            child = ConfigurationOption(child_name, self.__root)
            self.__children[item] = child
        return child

    def __getitem__(self, item):
        child = self.__children.get(item)
        if child is None:
            child_name = self.__name + (item,)
            child = ConfigurationOption(child_name, self.__root)
            self.__children[item] = child
        return child

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return new instance."""
        if self.__cache is not UNDEFINED:
            return self.__cache

        value = self.__root.get(self._get_self_name(), self.__required)
        self.__cache = value
        return value

    def _get_self_name(self):
        return ".".join(
            segment() if is_provider(segment) else segment for segment in self.__name
        )

    @property
    def root(self):
        return self.__root

    def get_name(self):
        return ".".join((self.__root.get_name(), self._get_self_name()))

    def get_name_segments(self):
        return self.__name

    def as_int(self):
        return TypedConfigurationOption(int, self)

    def as_float(self):
        return TypedConfigurationOption(float, self)

    def as_(self, callback, *args, **kwargs):
        return TypedConfigurationOption(callback, self, *args, **kwargs)

    def required(self):
        return self.__class__(self.__name, self.__root, required=True)

    def is_required(self):
        return self.__required

    def override(self, value):
        if isinstance(value, Provider):
            raise Error("Configuration option can only be overridden by a value")
        return self.__root.set(self._get_self_name(), value)

    def reset_last_overriding(self):
        raise Error("Configuration option does not support this method")

    def reset_override(self):
        raise Error("Configuration option does not support this method")

    def reset_cache(self):
        self.__cache = UNDEFINED

        for provider in self.__children.values():
            provider.reset_cache()

        for provider in self.overrides:
            if isinstance(provider, (Configuration, ConfigurationOption)):
                provider.reset_cache()

    def update(self, value):
        """Set configuration options.

        .. deprecated:: 3.11

            Use :py:meth:`Configuration.override` instead.

        :param value: Value of configuration option.
        :type value: object | dict

        :rtype: None
        """
        self.override(value)

    def from_ini(self, filepath, required=UNDEFINED, envs_required=UNDEFINED):
        """Load configuration from the ini file.

        Loaded configuration is merged recursively over existing configuration.

        :param filepath: Path to the configuration file.
        :type filepath: str

        :param required: When required is True, raise an exception if file does not exist.
        :type required: bool

        :param envs_required: When True, raises an error on undefined environment variable.
        :type envs_required: bool

        :rtype: None
        """
        try:
            parser = _parse_ini_file(
                filepath,
                envs_required=envs_required if envs_required is not UNDEFINED else self._is_strict_mode_enabled(),
            )
        except IOError as exception:
            if required is not False \
                    and (self._is_strict_mode_enabled() or required is True) \
                    and exception.errno in (errno.ENOENT, errno.EISDIR):
                exception.strerror = "Unable to load configuration file {0}".format(exception.strerror)
                raise
            return

        config = {}
        for section in parser.sections():
            config[section] = dict(parser.items(section))

        current_config = self.__call__()
        if not current_config:
            current_config = {}
        self.override(merge_dicts(current_config, config))

    def from_yaml(self, filepath, required=UNDEFINED, loader=None, envs_required=UNDEFINED):
        """Load configuration from the yaml file.

        Loaded configuration is merged recursively over existing configuration.

        :param filepath: Path to the configuration file.
        :type filepath: str

        :param required: When required is True, raise an exception if file does not exist.
        :type required: bool

        :param loader: YAML loader, :py:class:`YamlLoader` is used if not specified.
        :type loader: ``yaml.Loader``

        :param envs_required: When True, raises an error on undefined environment variable.
        :type envs_required: bool

        :rtype: None
        """
        if yaml is None:
            raise Error(
                "Unable to load yaml configuration - PyYAML is not installed. "
                "Install PyYAML or install Dependency Injector with yaml extras: "
                "\"pip install dependency-injector[yaml]\""
            )

        if loader is None:
            loader = YamlLoader

        try:
            with open(filepath) as opened_file:
                config_content = opened_file.read()
        except IOError as exception:
            if required is not False \
                    and (self._is_strict_mode_enabled() or required is True) \
                    and exception.errno in (errno.ENOENT, errno.EISDIR):
                exception.strerror = "Unable to load configuration file {0}".format(exception.strerror)
                raise
            return

        config_content = _resolve_config_env_markers(
            config_content,
            envs_required=envs_required if envs_required is not UNDEFINED else self._is_strict_mode_enabled(),
        )
        config = yaml.load(config_content, loader)

        current_config = self.__call__()
        if not current_config:
            current_config = {}
        self.override(merge_dicts(current_config, config))

    def from_json(self, filepath, required=UNDEFINED, envs_required=UNDEFINED):
        """Load configuration from a json file.

        Loaded configuration is merged recursively over the existing configuration.

        :param filepath: Path to a configuration file.
        :type filepath: str

        :param required: When required is True, raise an exception if file does not exist.
        :type required: bool

        :param envs_required: When True, raises an exception on undefined environment variable.
        :type envs_required: bool

        :rtype: None
        """
        try:
            with open(filepath) as opened_file:
                config_content = opened_file.read()
        except IOError as exception:
            if required is not False \
                    and (self._is_strict_mode_enabled() or required is True) \
                    and exception.errno in (errno.ENOENT, errno.EISDIR):
                exception.strerror = "Unable to load configuration file {0}".format(exception.strerror)
                raise
            return

        config_content = _resolve_config_env_markers(
            config_content,
            envs_required=envs_required if envs_required is not UNDEFINED else self._is_strict_mode_enabled(),
        )
        config = json.loads(config_content)

        current_config = self.__call__()
        if not current_config:
            current_config = {}
        self.override(merge_dicts(current_config, config))

    def from_pydantic(self, settings, required=UNDEFINED, **kwargs):
        """Load configuration from pydantic settings.

        Loaded configuration is merged recursively over existing configuration.

        :param settings: Pydantic settings instances.
        :type settings: :py:class:`pydantic_settings.BaseSettings`

        :param required: When required is True, raise an exception if settings dict is empty.
        :type required: bool

        :param kwargs: Keyword arguments forwarded to ``pydantic_settings.BaseSettings.dict()`` call.
        :type kwargs: Dict[Any, Any]

        :rtype: None
        """
        if pydantic is None:
            raise Error(
                "Unable to load pydantic configuration - pydantic is not installed. "
                "Install pydantic or install Dependency Injector with pydantic extras: "
                "\"pip install dependency-injector[pydantic]\""
            )

        if isinstance(settings, CLASS_TYPES) and issubclass(settings, pydantic_settings.BaseSettings):
            raise Error(
                "Got settings class, but expect instance: "
                "instead \"{0}\" use \"{0}()\"".format(settings.__name__)
            )

        if not isinstance(settings, pydantic_settings.BaseSettings):
            raise Error(
                "Unable to recognize settings instance, expect \"pydantic_settings.BaseSettings\", "
                "got {0} instead".format(settings)
            )

        self.from_dict(settings.dict(**kwargs), required=required)

    def from_dict(self, options, required=UNDEFINED):
        """Load configuration from the dictionary.

        Loaded configuration is merged recursively over existing configuration.

        :param options: Configuration options.
        :type options: dict

        :param required: When required is True, raise an exception if dictionary is empty.
        :type required: bool

        :rtype: None
        """
        if required is not False \
                and (self._is_strict_mode_enabled() or required is True) \
                and not options:
            raise ValueError("Can not use empty dictionary")

        try:
            current_config = self.__call__()
        except Error:
            current_config = {}
        else:
            if not current_config:
                current_config = {}

        self.override(merge_dicts(current_config, options))

    def from_env(self, name, default=UNDEFINED, required=UNDEFINED, as_=UNDEFINED):
        """Load configuration value from the environment variable.

        :param name: Name of the environment variable.
        :type name: str

        :param default: Default value that is used if environment variable does not exist.
        :type default: object

        :param required: When required is True, raise an exception if environment variable is undefined.
        :type required: bool

        :param as_: Callable used for type casting (int, float, etc).
        :type as_: object

        :rtype: None
        """
        value = os.environ.get(name, default)

        if value is UNDEFINED:
            if required is not False \
                    and (self._is_strict_mode_enabled() or required is True):
                raise ValueError("Environment variable \"{0}\" is undefined".format(name))
            value = None

        if as_ is not UNDEFINED:
            value = as_(value)

        self.override(value)

    def from_value(self, value):
        """Load configuration value.

        :param value: Configuration value
        :type value: object

        :rtype: None
        """
        self.override(value)

    @property
    def related(self):
        """Return related providers generator."""
        yield from filter(is_provider, self.__name)
        yield from self.__children.values()
        yield from super().related

    def _is_strict_mode_enabled(self):
        return self.__root.__strict


cdef class TypedConfigurationOption(Callable):

    @property
    def option(self):
        return self.args[0]


cdef class Configuration(Object):
    """Configuration provider provides configuration options to the other providers.

    .. code-block:: python

        config = Configuration("config")
        print(config.section1.option1())  # None
        print(config.section1.option2())  # None
        config.from_dict(
            {
                "section1": {
                    "option1": 1,
                    "option2": 2,
                },
            },
        )
        print(config.section1.option1())  # 1
        print(config.section1.option2())  # 2
    """

    DEFAULT_NAME = "config"

    def __init__(self, name=DEFAULT_NAME, default=None, strict=False, ini_files=None, yaml_files=None, json_files=None, pydantic_settings=None):
        self.__name = name
        self.__strict = strict
        self.__children = {}
        self.__ini_files = []
        self.__yaml_files = []
        self.__json_files = []
        self.__pydantic_settings = []

        super().__init__(provides={})
        self.set_default(default)

        if ini_files is None:
            ini_files = []
        self.set_ini_files(ini_files)

        if yaml_files is None:
            yaml_files = []
        self.set_yaml_files(yaml_files)

        if json_files is None:
            json_files = []
        self.set_json_files(json_files)

        if pydantic_settings is None:
            pydantic_settings = []
        self.set_pydantic_settings(pydantic_settings)

    def __deepcopy__(self, memo):
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_name(self.get_name())
        copied.set_default(self.get_default())
        copied.set_strict(self.get_strict())
        copied.set_children(deepcopy(self.get_children(), memo))
        copied.set_ini_files(self.get_ini_files())
        copied.set_yaml_files(self.get_yaml_files())
        copied.set_json_files(self.get_json_files())
        copied.set_pydantic_settings(self.get_pydantic_settings())

        self._copy_overridings(copied, memo)
        return copied

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        pass

    def __str__(self):
        return represent_provider(provider=self, provides=self.__name)

    def __getattr__(self, item):
        if item.startswith("__") and item.endswith("__"):
            raise AttributeError(
                "'{cls}' object has no attribute "
                "'{attribute_name}'".format(cls=self.__class__.__name__, attribute_name=item)
            )

        child = self.__children.get(item)
        if child is None:
            child = ConfigurationOption((item,), self)
            self.__children[item] = child
        return child

    def __getitem__(self, item):
        child = self.__children.get(item)
        if child is None:
            child = ConfigurationOption(item, self)
            self.__children[item] = child
        return child

    def get_name(self):
        """Return name."""
        return self.__name

    def set_name(self, name):
        """Set name."""
        self.__name = name
        return self

    def get_default(self):
        """Return default."""
        return self.provides

    def set_default(self, default):
        """Set default."""
        if not default:
            return self

        assert isinstance(default, dict), default
        self.set_provides(default.copy())
        return self

    def get_strict(self):
        """Return strict flag."""
        return self.__strict

    def set_strict(self, strict):
        """Set strict flag."""
        self.__strict = strict
        return self

    def get_children(self):
        """Return children options."""
        return self.__children

    def set_children(self, children):
        """Set children options."""
        self.__children = children
        return self

    def get_ini_files(self):
        """Return list of INI files."""
        return list(self.__ini_files)

    def set_ini_files(self, files):
        """Set list of INI files."""
        self.__ini_files = list(files)
        return self

    def get_yaml_files(self):
        """Return list of YAML files."""
        return list(self.__yaml_files)

    def set_yaml_files(self, files):
        """Set list of YAML files."""
        self.__yaml_files = list(files)
        return self

    def get_json_files(self):
        """Return list of JSON files."""
        return list(self.__json_files)

    def set_json_files(self, files):
        """Set list of JSON files."""
        self.__json_files = list(files)
        return self

    def get_pydantic_settings(self):
        """Return list of Pydantic settings."""
        return list(self.__pydantic_settings)

    def set_pydantic_settings(self, settings):
        """Set list of Pydantic settings."""
        self.__pydantic_settings = list(settings)
        return self

    def load(self, required=UNDEFINED, envs_required=UNDEFINED):
        """Load configuration.

        This method loads configuration from configuration files or pydantic settings that
        were set earlier with set_*() methods or provided to the __init__(), e.g.:

        .. code-block:: python

           config = providers.Configuration(yaml_files=[file1, file2])
           config.load()

        :param required: When required is True, raise an exception if file does not exist.
        :type required: bool

        :param envs_required: When True, raises an error on undefined environment variable.
        :type envs_required: bool
        """
        for file in self.get_ini_files():
            self.from_ini(file, required=required, envs_required=envs_required)

        for file in self.get_yaml_files():
            self.from_yaml(file, required=required, envs_required=envs_required)

        for file in self.get_json_files():
            self.from_json(file, required=required, envs_required=envs_required)

        for settings in self.get_pydantic_settings():
            self.from_pydantic(settings, required=required)

    def get(self, selector, required=False):
        """Return configuration option.

        :param selector: Selector string, e.g. "option1.option2"
        :type selector: str

        :param required: Required flag, raise error if required option is missing
        :type required: bool

        :return: Option value.
        :rtype: Any
        """
        value = self.__call__()

        if value is None:
            if self._is_strict_mode_enabled() or required:
                raise Error("Undefined configuration option \"{0}.{1}\"".format(self.__name, selector))
            return None

        keys = selector.split(".")
        while len(keys) > 0:
            key = keys.pop(0)
            value = value.get(key, UNDEFINED)

            if value is UNDEFINED:
                if self._is_strict_mode_enabled() or required:
                    raise Error("Undefined configuration option \"{0}.{1}\"".format(self.__name, selector))
                return None

        return value

    def set(self, selector, value):
        """Override configuration option.

        :param selector: Selector string, e.g. "option1.option2"
        :type selector: str

        :param value: Overriding value
        :type value: Any

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        original_value = current_value = deepcopy(self.__call__())

        keys = selector.split(".")
        while len(keys) > 0:
            key = keys.pop(0)
            if len(keys) == 0:
                current_value[key] = value
                break
            temp_value = current_value.get(key, {})
            current_value[key] = temp_value
            current_value = temp_value

        return self.override(original_value)

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        context = super().override(provider)
        self.reset_cache()
        return context

    def reset_last_overriding(self):
        """Reset last overriding provider.

        :raise: :py:exc:`dependency_injector.errors.Error` if provider is not
                overridden.

        :rtype: None
        """
        super().reset_last_overriding()
        self.reset_cache()

    def reset_override(self):
        """Reset all overriding providers.

        :rtype: None
        """
        super().reset_override()
        self.reset_cache()

    def reset_cache(self):
        """Reset children providers cache.

        :rtype: None
        """
        for provider in self.__children.values():
            provider.reset_cache()

        for provider in self.overrides:
            if isinstance(provider, (Configuration, ConfigurationOption)):
                provider.reset_cache()

    def update(self, value):
        """Set configuration options.

        .. deprecated:: 3.11

            Use :py:meth:`Configuration.override` instead.

        :param value: Value of configuration option.
        :type value: object | dict

        :rtype: None
        """
        self.override(value)

    def from_ini(self, filepath, required=UNDEFINED, envs_required=UNDEFINED):
        """Load configuration from the ini file.

        Loaded configuration is merged recursively over existing configuration.

        :param filepath: Path to the configuration file.
        :type filepath: str

        :param required: When required is True, raise an exception if file does not exist.
        :type required: bool

        :param envs_required: When True, raises an error on undefined environment variable.
        :type envs_required: bool

        :rtype: None
        """
        try:
            parser = _parse_ini_file(
                filepath,
                envs_required=envs_required if envs_required is not UNDEFINED else self._is_strict_mode_enabled(),
            )
        except IOError as exception:
            if required is not False \
                    and (self._is_strict_mode_enabled() or required is True) \
                    and exception.errno in (errno.ENOENT, errno.EISDIR):
                exception.strerror = "Unable to load configuration file {0}".format(exception.strerror)
                raise
            return

        config = {}
        for section in parser.sections():
            config[section] = dict(parser.items(section))

        current_config = self.__call__()
        if not current_config:
            current_config = {}
        self.override(merge_dicts(current_config, config))

    def from_yaml(self, filepath, required=UNDEFINED, loader=None, envs_required=UNDEFINED):
        """Load configuration from the yaml file.

        Loaded configuration is merged recursively over existing configuration.

        :param filepath: Path to the configuration file.
        :type filepath: str

        :param required: When required is True, raise an exception if file does not exist.
        :type required: bool

        :param loader: YAML loader, :py:class:`YamlLoader` is used if not specified.
        :type loader: ``yaml.Loader``

        :param envs_required: When True, raises an error on undefined environment variable.
        :type envs_required: bool

        :rtype: None
        """
        if yaml is None:
            raise Error(
                "Unable to load yaml configuration - PyYAML is not installed. "
                "Install PyYAML or install Dependency Injector with yaml extras: "
                "\"pip install dependency-injector[yaml]\""
            )

        if loader is None:
            loader = YamlLoader

        try:
            with open(filepath) as opened_file:
                config_content = opened_file.read()
        except IOError as exception:
            if required is not False \
                    and (self._is_strict_mode_enabled() or required is True) \
                    and exception.errno in (errno.ENOENT, errno.EISDIR):
                exception.strerror = "Unable to load configuration file {0}".format(exception.strerror)
                raise
            return

        config_content = _resolve_config_env_markers(
            config_content,
            envs_required=envs_required if envs_required is not UNDEFINED else self._is_strict_mode_enabled(),
        )
        config = yaml.load(config_content, loader)

        current_config = self.__call__()
        if not current_config:
            current_config = {}
        self.override(merge_dicts(current_config, config))

    def from_json(self, filepath, required=UNDEFINED, envs_required=UNDEFINED):
        """Load configuration from a json file.

        Loaded configuration is merged recursively over the existing configuration.

        :param filepath: Path to a configuration file.
        :type filepath: str

        :param required: When required is True, raise an exception if file does not exist.
        :type required: bool

        :param envs_required: When True, raises an exception on undefined environment variable.
        :type envs_required: bool

        :rtype: None
        """
        try:
            with open(filepath) as opened_file:
                config_content = opened_file.read()
        except IOError as exception:
            if required is not False \
                    and (self._is_strict_mode_enabled() or required is True) \
                    and exception.errno in (errno.ENOENT, errno.EISDIR):
                exception.strerror = "Unable to load configuration file {0}".format(exception.strerror)
                raise
            return

        config_content = _resolve_config_env_markers(
            config_content,
            envs_required=envs_required if envs_required is not UNDEFINED else self._is_strict_mode_enabled(),
        )
        config = json.loads(config_content)

        current_config = self.__call__()
        if not current_config:
            current_config = {}
        self.override(merge_dicts(current_config, config))

    def from_pydantic(self, settings, required=UNDEFINED, **kwargs):
        """Load configuration from pydantic settings.

        Loaded configuration is merged recursively over existing configuration.

        :param settings: Pydantic settings instances.
        :type settings: :py:class:`pydantic_settings.BaseSettings`

        :param required: When required is True, raise an exception if settings dict is empty.
        :type required: bool

        :param kwargs: Keyword arguments forwarded to ``pydantic_settings.BaseSettings.dict()`` call.
        :type kwargs: Dict[Any, Any]

        :rtype: None
        """
        if pydantic is None:
            raise Error(
                "Unable to load pydantic configuration - pydantic is not installed. "
                "Install pydantic or install Dependency Injector with pydantic extras: "
                "\"pip install dependency-injector[pydantic]\""
            )

        if isinstance(settings, CLASS_TYPES) and issubclass(settings, pydantic_settings.BaseSettings):
            raise Error(
                "Got settings class, but expect instance: "
                "instead \"{0}\" use \"{0}()\"".format(settings.__name__)
            )

        if not isinstance(settings, pydantic_settings.BaseSettings):
            raise Error(
                "Unable to recognize settings instance, expect \"pydantic_settings.BaseSettings\", "
                "got {0} instead".format(settings)
            )

        self.from_dict(settings.dict(**kwargs), required=required)

    def from_dict(self, options, required=UNDEFINED):
        """Load configuration from the dictionary.

        Loaded configuration is merged recursively over existing configuration.

        :param options: Configuration options.
        :type options: dict

        :param required: When required is True, raise an exception if dictionary is empty.
        :type required: bool

        :rtype: None
        """
        if required is not False \
                and (self._is_strict_mode_enabled() or required is True) \
                and not options:
            raise ValueError("Can not use empty dictionary")

        current_config = self.__call__()
        if not current_config:
            current_config = {}
        self.override(merge_dicts(current_config, options))

    def from_env(self, name, default=UNDEFINED, required=UNDEFINED, as_=UNDEFINED):
        """Load configuration value from the environment variable.

        :param name: Name of the environment variable.
        :type name: str

        :param default: Default value that is used if environment variable does not exist.
        :type default: object

        :param required: When required is True, raise an exception if environment variable is undefined.
        :type required: bool

        :param as_: Callable used for type casting (int, float, etc).
        :type as_: object

        :rtype: None
        """
        value = os.environ.get(name, default)

        if value is UNDEFINED:
            if required is not False \
                    and (self._is_strict_mode_enabled() or required is True):
                raise ValueError("Environment variable \"{0}\" is undefined".format(name))
            value = None

        if as_ is not UNDEFINED:
            value = as_(value)

        self.override(value)

    def from_value(self, value):
        """Load configuration value.

        :param value: Configuration value
        :type value: object

        :rtype: None
        """
        self.override(value)

    @property
    def related(self):
        """Return related providers generator."""
        yield from self.__children.values()
        yield from super().related

    def _is_strict_mode_enabled(self):
        return self.__strict


cdef class Factory(Provider):
    r"""Factory provider creates new instance on every call.

    :py:class:`Factory` supports positional & keyword argument injections,
    as well as attribute injections.

    Positional and keyword argument injections could be defined like this:

    .. code-block:: python

        factory = Factory(SomeClass,
                          "positional_arg1", "positional_arg2",
                          keyword_argument1=3, keyword_argument=4)

        # or

        factory = Factory(SomeClass) \
            .add_args("positional_arg1", "positional_arg2") \
            .add_kwargs(keyword_argument1=3, keyword_argument=4)

        # or

        factory = Factory(SomeClass)
        factory.add_args("positional_arg1", "positional_arg2")
        factory.add_kwargs(keyword_argument1=3, keyword_argument=4)


    Attribute injections are defined by using
    :py:meth:`Factory.add_attributes`:

    .. code-block:: python

        factory = Factory(SomeClass) \
            .add_attributes(attribute1=1, attribute2=2)

    Retrieving of provided instance can be performed via calling
    :py:class:`Factory` object:

    .. code-block:: python

        factory = Factory(SomeClass)
        some_object = factory()

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None
    """

    provided_type = None

    def __init__(self, provides=None, *args, **kwargs):
        """Initialize provider."""
        self.__instantiator = Callable()
        self.set_provides(provides)
        self.set_args(*args)
        self.set_kwargs(**kwargs)

        self.__attributes = tuple()
        self.__attributes_len = 0

        super(Factory, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_provides(_copy_if_provider(self.provides, memo))
        copied.set_args(*deepcopy(self.args, memo))
        copied.set_kwargs(**deepcopy(self.kwargs, memo))
        copied.set_attributes(**deepcopy(self.attributes, memo))
        self._copy_overridings(copied, memo)
        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self,
                                  provides=self.__instantiator.provides)

    @property
    def cls(self):
        """Return provided type."""
        return self.provides

    @property
    def provides(self):
        """Return provider provides."""
        return self.__instantiator.provides

    def set_provides(self, provides):
        """Set provider provides."""
        provides = _resolve_string_import(provides)
        if (provides
                and self.__class__.provided_type and
                not issubclass(provides, self.__class__.provided_type)):
            raise Error(
                "{0} can provide only {1} instances".format(
                    _class_qualname(self),
                    self.__class__.provided_type,
                ),
            )
        self.__instantiator.set_provides(provides)
        return self

    @property
    def args(self):
        """Return positional argument injections."""
        return self.__instantiator.args

    def add_args(self, *args):
        """Add __init__ positional argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.add_args(*args)
        return self

    def set_args(self, *args):
        """Set __init__ positional argument injections.

        Existing __init__ positional argument injections are dropped.

        :return: Reference ``self``
        """
        self.__instantiator.set_args(*args)
        return self

    def clear_args(self):
        """Drop __init__ positional argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.clear_args()
        return self

    @property
    def kwargs(self):
        """Return keyword argument injections."""
        return self.__instantiator.kwargs

    def add_kwargs(self, **kwargs):
        """Add __init__ keyword argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.add_kwargs(**kwargs)
        return self

    def set_kwargs(self, **kwargs):
        """Set __init__ keyword argument injections.

        Existing __init__ keyword argument injections are dropped.

        :return: Reference ``self``
        """
        self.__instantiator.set_kwargs(**kwargs)
        return self

    def clear_kwargs(self):
        """Drop __init__ keyword argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.clear_kwargs()
        return self

    @property
    def attributes(self):
        """Return attribute injections."""
        cdef int index
        cdef NamedInjection attribute
        cdef dict attributes

        attributes = dict()
        for index in range(self.__attributes_len):
            attribute = self.__attributes[index]
            attributes[attribute.__name] = attribute.__value
        return attributes

    def add_attributes(self, **kwargs):
        """Add attribute injections.

        :return: Reference ``self``
        """
        self.__attributes += parse_named_injections(kwargs)
        self.__attributes_len = len(self.__attributes)
        return self

    def set_attributes(self, **kwargs):
        """Set attribute injections.

        Existing attribute injections are dropped.

        :return: Reference ``self``
        """
        self.__attributes = parse_named_injections(kwargs)
        self.__attributes_len = len(self.__attributes)
        return self

    def clear_attributes(self):
        """Drop attribute injections.

        :return: Reference ``self``
        """
        self.__attributes = tuple()
        self.__attributes_len = len(self.__attributes)
        return self

    @property
    def related(self):
        """Return related providers generator."""
        yield from filter(is_provider, [self.provides])
        yield from filter(is_provider, self.args)
        yield from filter(is_provider, self.kwargs.values())
        yield from filter(is_provider, self.attributes.values())
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return new instance."""
        return __factory_call(self, args, kwargs)


cdef class DelegatedFactory(Factory):
    """Factory that is injected "as is".

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls
       :noindex:

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    __IS_DELEGATED__ = True


cdef class AbstractFactory(Factory):
    """Abstract factory provider.

    :py:class:`AbstractFactory` is a :py:class:`Factory` provider that must
    be explicitly overridden before calling.

    Overriding of :py:class:`AbstractFactory` is possible only by another
    :py:class:`Factory` provider.
    """

    def __call__(self, *args, **kwargs):
        """Return provided object.

        Callable interface implementation.
        """
        if self.__last_overriding is None:
            raise Error("{0} must be overridden before calling".format(self))
        return super().__call__(*args, **kwargs)

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        if not isinstance(provider, Factory):
            raise Error("{0} must be overridden only by "
                        "{1} providers".format(self, Factory))
        return super(AbstractFactory, self).override(provider)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return result of provided callable call."""
        raise NotImplementedError("Abstract provider forward providing logic to overriding provider")


cdef class FactoryDelegate(Delegate):
    """Factory delegate injects delegating factory "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, factory):
        """Initializer.

        :param factory: Value that have to be provided.
        :type factory: object
        """
        if isinstance(factory, Factory) is False:
            raise Error("{0} can wrap only {1} providers".format(self.__class__, Factory))
        super(FactoryDelegate, self).__init__(factory)


cdef class FactoryAggregate(Aggregate):
    """Factory providers aggregate.

    :py:class:`FactoryAggregate` is an aggregate of :py:class:`Factory`
    providers.

    :py:class:`FactoryAggregate` is a delegated provider, meaning that it is
    injected "as is".

    All aggregated providers can be retrieved as a read-only
    dictionary :py:attr:`FactoryAggregate.providers` or as an attribute of
    :py:class:`FactoryAggregate`.
    """

    @property
    def factories(self):
        """Return dictionary of factories, read-only.

        Alias for ``.providers()`` attribute.
        """
        return self.providers

    def set_factories(self, factory_dict=None, **factory_kwargs):
        """Set factories.

        Alias for ``.set_providers()`` method.
        """
        return self.set_providers(factory_dict, **factory_kwargs)


cdef class BaseSingleton(Provider):
    """Base class of singleton providers."""

    provided_type = None

    def __init__(self, provides=None, *args, **kwargs):
        """Initialize provider."""
        self.__instantiator = Factory()
        self.set_provides(provides)
        self.set_args(*args)
        self.set_kwargs(**kwargs)
        super(BaseSingleton, self).__init__()

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self,
                                  provides=self.__instantiator.cls)

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_provides(_copy_if_provider(self.provides, memo))
        copied.set_args(*deepcopy(self.args, memo))
        copied.set_kwargs(**deepcopy(self.kwargs, memo))
        copied.set_attributes(**deepcopy(self.attributes, memo))
        self._copy_overridings(copied, memo)
        return copied

    @property
    def cls(self):
        """Return provided type."""
        return self.provides

    @property
    def provides(self):
        """Return provider provides."""
        return self.__instantiator.provides

    def set_provides(self, provides):
        """Set provider provides."""
        provides = _resolve_string_import(provides)
        if (provides
                and self.__class__.provided_type and
                not issubclass(provides, self.__class__.provided_type)):
            raise Error(
                "{0} can provide only {1} instances".format(
                    _class_qualname(self),
                    self.__class__.provided_type,
                ),
            )
        self.__instantiator.set_provides(provides)
        return self

    @property
    def args(self):
        """Return positional argument injections."""
        return self.__instantiator.args

    def add_args(self, *args):
        """Add __init__ positional argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.add_args(*args)
        return self

    def set_args(self, *args):
        """Set __init__ positional argument injections.

        Existing __init__ positional argument injections are dropped.

        :return: Reference ``self``
        """
        self.__instantiator.set_args(*args)
        return self

    def clear_args(self):
        """Drop __init__ positional argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.clear_args()
        return self

    @property
    def kwargs(self):
        """Return keyword argument injections."""
        return self.__instantiator.kwargs

    def add_kwargs(self, **kwargs):
        """Add __init__ keyword argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.add_kwargs(**kwargs)
        return self

    def set_kwargs(self, **kwargs):
        """Set __init__ keyword argument injections.

        Existing __init__ keyword argument injections are dropped.

        :return: Reference ``self``
        """
        self.__instantiator.set_kwargs(**kwargs)
        return self

    def clear_kwargs(self):
        """Drop __init__ keyword argument injections.

        :return: Reference ``self``
        """
        self.__instantiator.clear_kwargs()
        return self

    @property
    def attributes(self):
        """Return attribute injections."""
        return self.__instantiator.attributes

    def add_attributes(self, **kwargs):
        """Add attribute injections.

        :return: Reference ``self``
        """
        self.__instantiator.add_attributes(**kwargs)
        return self

    def set_attributes(self, **kwargs):
        """Set attribute injections.

        Existing attribute injections are dropped.

        :return: Reference ``self``
        """
        self.__instantiator.set_attributes(**kwargs)
        return self

    def clear_attributes(self):
        """Drop attribute injections.

        :return: Reference ``self``
        """
        self.__instantiator.clear_attributes()
        return self

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        raise NotImplementedError()

    def full_reset(self):
        """Reset cached instance in current and all underlying singletons, if any.

        :rtype: :py:class:`SingletonFullResetContext`
        """
        self.reset()
        for provider in self.traverse(types=[BaseSingleton]):
            provider.reset()
        return SingletonFullResetContext(self)

    @property
    def related(self):
        """Return related providers generator."""
        yield from filter(is_provider, [self.__instantiator.provides])
        yield from filter(is_provider, self.args)
        yield from filter(is_provider, self.kwargs.values())
        yield from filter(is_provider, self.attributes.values())
        yield from super().related

    def _async_init_instance(self, future_result, result):
        try:
            instance = result.result()
        except Exception as exception:
            self.__storage = None
            future_result.set_exception(exception)
        else:
            self.__storage = instance
            future_result.set_result(instance)


cdef class Singleton(BaseSingleton):
    """Singleton provider returns same instance on every call.

    :py:class:`Singleton` provider creates instance once and returns it on
    every call. :py:class:`Singleton` extends :py:class:`Factory`, so, please
    follow :py:class:`Factory` documentation for getting familiar with
    injections syntax.

    Retrieving of provided instance can be performed via calling
    :py:class:`Singleton` object:

    .. code-block:: python

        singleton = Singleton(SomeClass)
        some_object = singleton()

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls
       :noindex:

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    def __init__(self, provides=None, *args, **kwargs):
        """Initializer.

        :param provides: Provided type.
        :type provides: type
        """
        self.__storage = None
        super(Singleton, self).__init__(provides, *args, **kwargs)

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        if __is_future_or_coroutine(self.__storage):
            asyncio.ensure_future(self.__storage).cancel()
        self.__storage = None
        return SingletonResetContext(self)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return single instance."""
        if self.__storage is None:
            instance = __factory_call(self.__instantiator, args, kwargs)

            if __is_future_or_coroutine(instance):
                future_result = asyncio.Future()
                instance = asyncio.ensure_future(instance)
                instance.add_done_callback(functools.partial(self._async_init_instance, future_result))
                self.__storage = future_result
                return future_result

            self.__storage = instance

        return self.__storage


cdef class DelegatedSingleton(Singleton):
    """Delegated singleton is injected "as is".

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls
       :noindex:

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    __IS_DELEGATED__ = True


cdef class ThreadSafeSingleton(BaseSingleton):
    """Thread-safe singleton provider."""

    storage_lock = threading.RLock()
    """Storage reentrant lock.

    :type: :py:class:`threading.RLock`
    """

    def __init__(self, provides=None, *args, **kwargs):
        """Initializer.

        :param provides: Provided type.
        :type provides: type
        """
        self.__storage = None
        self.__storage_lock = self.__class__.storage_lock
        super(ThreadSafeSingleton, self).__init__(provides, *args, **kwargs)

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        with self.__storage_lock:
            if __is_future_or_coroutine(self.__storage):
                asyncio.ensure_future(self.__storage).cancel()
            self.__storage = None
        return SingletonResetContext(self)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return single instance."""
        instance = self.__storage

        if instance is None:
            with self.__storage_lock:
                if self.__storage is None:
                    result = __factory_call(self.__instantiator, args, kwargs)
                    if __is_future_or_coroutine(result):
                        future_result = asyncio.Future()
                        result = asyncio.ensure_future(result)
                        result.add_done_callback(functools.partial(self._async_init_instance, future_result))
                        result = future_result
                    self.__storage = result
                instance = self.__storage
        return instance


cdef class DelegatedThreadSafeSingleton(ThreadSafeSingleton):
    """Delegated thread-safe singleton is injected "as is".

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls
       :noindex:

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    __IS_DELEGATED__ = True


cdef class ThreadLocalSingleton(BaseSingleton):
    """Thread-local singleton provides single objects in scope of thread.

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls
       :noindex:

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    def __init__(self, provides=None, *args, **kwargs):
        """Initializer.

        :param provides: Provided type.
        :type provides: type
        """
        self.__storage = threading.local()
        super(ThreadLocalSingleton, self).__init__(provides, *args, **kwargs)

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        try:
            instance = self.__storage.instance
        except AttributeError:
            return SingletonResetContext(self)

        if __is_future_or_coroutine(instance):
            asyncio.ensure_future(instance).cancel()

        del self.__storage.instance

        return SingletonResetContext(self)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return single instance."""
        cdef object instance

        try:
            instance = self.__storage.instance
        except AttributeError:
            instance = __factory_call(self.__instantiator, args, kwargs)

            if __is_future_or_coroutine(instance):
                future_result = asyncio.Future()
                instance = asyncio.ensure_future(instance)
                instance.add_done_callback(functools.partial(self._async_init_instance, future_result))
                self.__storage.instance = future_result
                return future_result

            self.__storage.instance = instance
        finally:
            return instance

    def _async_init_instance(self, future_result, result):
        try:
            instance = result.result()
        except Exception as exception:
            del self.__storage.instance
            future_result.set_exception(exception)
        else:
            self.__storage.instance = instance
            future_result.set_result(instance)


cdef class ContextLocalSingleton(BaseSingleton):
    """Context-local singleton provides single objects in scope of a context.

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls
       :noindex:

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """
    _none = object()

    def __init__(self, provides=None, *args, **kwargs):
        """Initializer.

        :param provides: Provided type.
        :type provides: type
        """
        if not contextvars:
            raise RuntimeError(
                "Contextvars library not found. This provider "
                "requires Python 3.7 or a backport of contextvars. "
                "To install a backport run \"pip install contextvars\"."
            )

        super(ContextLocalSingleton, self).__init__(provides, *args, **kwargs)
        self.__storage = contextvars.ContextVar("__storage", default=self._none)

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        instance = self.__storage.get()
        if instance is self._none:
            return SingletonResetContext(self)

        if __is_future_or_coroutine(instance):
            asyncio.ensure_future(instance).cancel()

        self.__storage.set(self._none)

        return SingletonResetContext(self)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return single instance."""
        cdef object instance

        instance = self.__storage.get()

        if instance is self._none:
            instance = __factory_call(self.__instantiator, args, kwargs)

            if __is_future_or_coroutine(instance):
                future_result = asyncio.Future()
                instance = asyncio.ensure_future(instance)
                instance.add_done_callback(functools.partial(self._async_init_instance, future_result))
                self.__storage.set(future_result)
                return future_result

            self.__storage.set(instance)

        return instance

    def _async_init_instance(self, future_result, result):
        try:
            instance = result.result()
        except Exception as exception:
            self.__storage.set(self._none)
            future_result.set_exception(exception)
        else:
            self.__storage.set(instance)
            future_result.set_result(instance)


cdef class DelegatedThreadLocalSingleton(ThreadLocalSingleton):
    """Delegated thread-local singleton is injected "as is".

    .. py:attribute:: provided_type

        If provided type is defined, provider checks that providing class is
        its subclass.

        :type: type | None

    .. py:attribute:: cls
       :noindex:

        Class that provides object.
        Alias for :py:attr:`provides`.

        :type: type
    """

    __IS_DELEGATED__ = True


cdef class AbstractSingleton(BaseSingleton):
    """Abstract singleton provider.

    :py:class:`AbstractSingleton` is a :py:class:`Singleton` provider that must
    be explicitly overridden before calling.

    Overriding of :py:class:`AbstractSingleton` is possible only by another
    :py:class:`BaseSingleton` provider.
    """

    def __call__(self, *args, **kwargs):
        """Return provided object.

        Callable interface implementation.
        """
        if self.__last_overriding is None:
            raise Error("{0} must be overridden before calling".format(self))
        return super().__call__(*args, **kwargs)

    def override(self, provider):
        """Override provider with another provider.

        :param provider: Overriding provider.
        :type provider: :py:class:`Provider`

        :raise: :py:exc:`dependency_injector.errors.Error`

        :return: Overriding context.
        :rtype: :py:class:`OverridingContext`
        """
        if not isinstance(provider, BaseSingleton):
            raise Error("{0} must be overridden only by "
                        "{1} providers".format(self, BaseSingleton))
        return super(AbstractSingleton, self).override(provider)

    def reset(self):
        """Reset cached instance, if any.

        :rtype: None
        """
        if self.__last_overriding is None:
            raise Error("{0} must be overridden before calling".format(self))
        return self.__last_overriding.reset()


cdef class SingletonDelegate(Delegate):
    """Singleton delegate injects delegating singleton "as is".

    .. py:attribute:: provides

        Value that have to be provided.

        :type: object
    """

    def __init__(self, singleton):
        """Initializer.

        :param singleton: Value that have to be provided.
        :type singleton: py:class:`BaseSingleton`
        """
        if isinstance(singleton, BaseSingleton) is False:
            raise Error("{0} can wrap only {1} providers".format(
                self.__class__, BaseSingleton))
        super(SingletonDelegate, self).__init__(singleton)


cdef class List(Provider):
    """List provider provides a list of values.

    :py:class:`List` provider is needed for injecting a list of dependencies. It handles
    positional argument injections the same way as :py:class:`Factory` provider.

    Keyword argument injections are not supported.

    .. code-block:: python

        dispatcher_factory = Factory(
            Dispatcher,
            modules=List(
                Factory(ModuleA, dependency_a),
                Factory(ModuleB, dependency_b),
            ),
        )

        dispatcher = dispatcher_factory()

        # is equivalent to:

        dispatcher = Dispatcher(
            modules=[
                ModuleA(dependency_a),
                ModuleB(dependency_b),
            ],
        )
    """

    def __init__(self, *args):
        """Initializer."""
        self.__args = tuple()
        self.__args_len = 0
        self.set_args(*args)
        super(List, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_args(*deepcopy(self.args, memo))
        self._copy_overridings(copied, memo)
        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=list(self.args))

    @property
    def args(self):
        """Return positional argument injections."""
        cdef int index
        cdef PositionalInjection arg
        cdef list args

        args = list()
        for index in range(self.__args_len):
            arg = self.__args[index]
            args.append(arg.__value)
        return tuple(args)

    def add_args(self, *args):
        """Add positional argument injections.

        :return: Reference ``self``
        """
        self.__args += parse_positional_injections(args)
        self.__args_len = len(self.__args)
        return self

    def set_args(self, *args):
        """Set positional argument injections.

        Existing positional argument injections are dropped.

        :return: Reference ``self``
        """
        self.__args = parse_positional_injections(args)
        self.__args_len = len(self.__args)
        return self

    def clear_args(self):
        """Drop positional argument injections.

        :return: Reference ``self``
        """
        self.__args = tuple()
        self.__args_len = len(self.__args)
        return self

    @property
    def related(self):
        """Return related providers generator."""
        yield from filter(is_provider, self.args)
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return result of provided callable call."""
        return __provide_positional_args(args, self.__args, self.__args_len, self.__async_mode)


cdef class Dict(Provider):
    """Dict provider provides a dictionary of values.

    :py:class:`Dict` provider is needed for injecting a dictionary of dependencies. It handles
    keyword argument injections the same way as :py:class:`Factory` provider.

    Positional argument injections are not supported.

    .. code-block:: python

        dispatcher_factory = Factory(
            Dispatcher,
            modules=Dict(
                module1=Factory(ModuleA, dependency_a),
                module2=Factory(ModuleB, dependency_b),
            ),
        )

        dispatcher = dispatcher_factory()

        # is equivalent to:

        dispatcher = Dispatcher(
            modules={
                "module1": ModuleA(dependency_a),
                "module2": ModuleB(dependency_b),
            },
        )
    """

    def __init__(self, dict_=None, **kwargs):
        """Initializer."""
        self.__kwargs = tuple()
        self.__kwargs_len = 0
        self.add_kwargs(dict_, **kwargs)
        super(Dict, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        self._copy_kwargs(copied, memo)
        self._copy_overridings(copied, memo)
        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.kwargs)

    @property
    def kwargs(self):
        """Return keyword argument injections."""
        cdef int index
        cdef NamedInjection kwarg
        cdef dict kwargs

        kwargs = dict()
        for index in range(self.__kwargs_len):
            kwarg = self.__kwargs[index]
            kwargs[kwarg.__name] = kwarg.__value
        return kwargs

    def add_kwargs(self, dict_=None, **kwargs):
        """Add keyword argument injections.

        :return: Reference ``self``
        """
        if dict_ is None:
            dict_ = {}

        self.__kwargs += parse_named_injections(dict_)
        self.__kwargs += parse_named_injections(kwargs)
        self.__kwargs_len = len(self.__kwargs)

        return self

    def set_kwargs(self, dict_=None, **kwargs):
        """Set keyword argument injections.

        Existing keyword argument injections are dropped.

        :return: Reference ``self``
        """
        if dict_ is None:
            dict_ = {}

        self.__kwargs = parse_named_injections(dict_)
        self.__kwargs += parse_named_injections(kwargs)
        self.__kwargs_len = len(self.__kwargs)

        return self

    def clear_kwargs(self):
        """Drop keyword argument injections.

        :return: Reference ``self``
        """
        self.__kwargs = tuple()
        self.__kwargs_len = len(self.__kwargs)
        return self

    @property
    def related(self):
        """Return related providers generator."""
        yield from filter(is_provider, self.kwargs.values())
        yield from super().related

    def _copy_kwargs(self, copied, memo):
        """Return copy of kwargs."""
        copied_kwargs = {
            _copy_if_provider(name, memo): _copy_if_provider(value, memo)
            for name, value in self.kwargs.items()
        }
        copied.set_kwargs(copied_kwargs)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return result of provided callable call."""
        return __provide_keyword_args(kwargs, self.__kwargs, self.__kwargs_len, self.__async_mode)



cdef class Resource(Provider):
    """Resource provider provides a component with initialization and shutdown."""

    def __init__(self, provides=None, *args, **kwargs):
        self.__provides = None
        self.set_provides(provides)

        self.__initialized = False
        self.__resource = None
        self.__shutdowner = None

        self.__args = tuple()
        self.__args_len = 0
        self.set_args(*args)

        self.__kwargs = tuple()
        self.__kwargs_len = 0
        self.set_kwargs(**kwargs)

        super().__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        if self.__initialized:
            raise Error("Can not copy initialized resource")

        copied = _memorized_duplicate(self, memo)
        copied.set_provides(_copy_if_provider(self.provides, memo))
        copied.set_args(*deepcopy(self.args, memo))
        copied.set_kwargs(**deepcopy(self.kwargs, memo))

        self._copy_overridings(copied, memo)

        return copied

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """
        return represent_provider(provider=self, provides=self.provides)

    @property
    def provides(self):
        """Return provider provides."""
        return self.__provides

    def set_provides(self, provides):
        """Set provider provides."""
        provides = _resolve_string_import(provides)
        self.__provides = provides
        return self

    @property
    def args(self):
        """Return positional argument injections."""
        cdef int index
        cdef PositionalInjection arg
        cdef list args

        args = list()
        for index in range(self.__args_len):
            arg = self.__args[index]
            args.append(arg.__value)
        return tuple(args)

    def add_args(self, *args):
        """Add positional argument injections.

        :return: Reference ``self``
        """
        self.__args += parse_positional_injections(args)
        self.__args_len = len(self.__args)
        return self

    def set_args(self, *args):
        """Set positional argument injections.

        Existing positional argument injections are dropped.

        :return: Reference ``self``
        """
        self.__args = parse_positional_injections(args)
        self.__args_len = len(self.__args)
        return self

    def clear_args(self):
        """Drop positional argument injections.

        :return: Reference ``self``
        """
        self.__args = tuple()
        self.__args_len = len(self.__args)
        return self

    @property
    def kwargs(self):
        """Return keyword argument injections."""
        cdef int index
        cdef NamedInjection kwarg
        cdef dict kwargs

        kwargs = dict()
        for index in range(self.__kwargs_len):
            kwarg = self.__kwargs[index]
            kwargs[kwarg.__name] = kwarg.__value
        return kwargs

    def add_kwargs(self, **kwargs):
        """Add keyword argument injections.

        :return: Reference ``self``
        """
        self.__kwargs += parse_named_injections(kwargs)
        self.__kwargs_len = len(self.__kwargs)
        return self

    def set_kwargs(self, **kwargs):
        """Set keyword argument injections.

        Existing keyword argument injections are dropped.

        :return: Reference ``self``
        """
        self.__kwargs = parse_named_injections(kwargs)
        self.__kwargs_len = len(self.__kwargs)
        return self

    def clear_kwargs(self):
        """Drop keyword argument injections.

        :return: Reference ``self``
        """
        self.__kwargs = tuple()
        self.__kwargs_len = len(self.__kwargs)
        return self

    @property
    def initialized(self):
        """Check if resource is initialized."""
        return self.__initialized

    def init(self):
        """Initialize resource."""
        return self.__call__()

    def shutdown(self):
        """Shutdown resource."""
        if not self.__initialized:
            if self.__async_mode == ASYNC_MODE_ENABLED:
                result = asyncio.Future()
                result.set_result(None)
                return result
            return

        if self.__shutdowner:
            try:
                shutdown = self.__shutdowner(self.__resource)
            except StopIteration:
                pass
            else:
                if inspect.isawaitable(shutdown):
                    return self._create_shutdown_future(shutdown)

        self.__resource = None
        self.__initialized = False
        self.__shutdowner = None

        if self.__async_mode == ASYNC_MODE_ENABLED:
            result = asyncio.Future()
            result.set_result(None)
            return result

    @property
    def related(self):
        """Return related providers generator."""
        yield from filter(is_provider, [self.provides])
        yield from filter(is_provider, self.args)
        yield from filter(is_provider, self.kwargs.values())
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        if self.__initialized:
            return self.__resource

        if self._is_resource_subclass(self.__provides):
            initializer = self.__provides()
            self.__resource = __call(
                initializer.init,
                args,
                self.__args,
                self.__args_len,
                kwargs,
                self.__kwargs,
                self.__kwargs_len,
                self.__async_mode,
            )
            self.__shutdowner = initializer.shutdown
        elif self._is_async_resource_subclass(self.__provides):
            initializer = self.__provides()
            async_init = __call(
                initializer.init,
                args,
                self.__args,
                self.__args_len,
                kwargs,
                self.__kwargs,
                self.__kwargs_len,
                self.__async_mode,
            )
            self.__initialized = True
            return self._create_init_future(async_init, initializer.shutdown)
        elif inspect.isgeneratorfunction(self.__provides):
            initializer = __call(
                self.__provides,
                args,
                self.__args,
                self.__args_len,
                kwargs,
                self.__kwargs,
                self.__kwargs_len,
                self.__async_mode,
            )
            self.__resource = next(initializer)
            self.__shutdowner = initializer.send
        elif iscoroutinefunction(self.__provides):
            initializer = __call(
                self.__provides,
                args,
                self.__args,
                self.__args_len,
                kwargs,
                self.__kwargs,
                self.__kwargs_len,
                self.__async_mode,
            )
            self.__initialized = True
            return self._create_init_future(initializer)
        elif isasyncgenfunction(self.__provides):
            initializer = __call(
                self.__provides,
                args,
                self.__args,
                self.__args_len,
                kwargs,
                self.__kwargs,
                self.__kwargs_len,
                self.__async_mode,
            )
            self.__initialized = True
            return self._create_async_gen_init_future(initializer)
        elif callable(self.__provides):
            self.__resource = __call(
                self.__provides,
                args,
                self.__args,
                self.__args_len,
                kwargs,
                self.__kwargs,
                self.__kwargs_len,
                self.__async_mode,
            )
        else:
            raise Error("Unknown type of resource initializer")

        self.__initialized = True
        return self.__resource

    def _create_init_future(self, future, shutdowner=None):
        callback = self._async_init_callback
        if shutdowner:
            callback = functools.partial(callback, shutdowner=shutdowner)

        future = asyncio.ensure_future(future)
        future.add_done_callback(callback)
        self.__resource = future

        return future

    def _create_async_gen_init_future(self, initializer):
        if inspect.isasyncgen(initializer):
            return self._create_init_future(initializer.__anext__(), initializer.asend)

        future = asyncio.Future()

        create_initializer = asyncio.ensure_future(initializer)
        create_initializer.add_done_callback(functools.partial(self._async_create_gen_callback, future))
        self.__resource = future

        return future

    def _async_init_callback(self, initializer, shutdowner=None):
        try:
            resource = initializer.result()
        except Exception:
            self.__initialized = False
        else:
            self.__resource = resource
            self.__shutdowner = shutdowner

    def _async_create_gen_callback(self, future, initializer_future):
        initializer = initializer_future.result()
        init_future = self._create_init_future(initializer.__anext__(), initializer.asend)
        init_future.add_done_callback(functools.partial(self._async_trigger_result, future))

    def _async_trigger_result(self, future, future_result):
        future.set_result(future_result.result())

    def _create_shutdown_future(self, shutdown_future):
        future = asyncio.Future()
        shutdown_future = asyncio.ensure_future(shutdown_future)
        shutdown_future.add_done_callback(functools.partial(self._async_shutdown_callback, future))
        return future

    def _async_shutdown_callback(self, future_result, shutdowner):
        try:
            shutdowner.result()
        except StopAsyncIteration:
            pass

        self.__resource = None
        self.__initialized = False
        self.__shutdowner = None

        future_result.set_result(None)

    @staticmethod
    def _is_resource_subclass(instance):
        if  sys.version_info < (3, 5):
            return False
        if not isinstance(instance, CLASS_TYPES):
            return
        from . import resources
        return issubclass(instance, resources.Resource)

    @staticmethod
    def _is_async_resource_subclass(instance):
        if  sys.version_info < (3, 5):
            return False
        if not isinstance(instance, CLASS_TYPES):
            return
        from . import resources
        return issubclass(instance, resources.AsyncResource)


cdef class Container(Provider):
    """Container provider provides an instance of declarative container.

    .. warning::
        Provider is experimental. Its interface may change.
    """

    def __init__(self, container_cls=None, container=None, **overriding_providers):
        """Initialize provider."""
        self.__container_cls = container_cls
        self.__overriding_providers = overriding_providers

        if container is None and container_cls:
            container = container_cls()
            container.assign_parent(self)
        self.__container = container

        if self.__container and self.__overriding_providers:
            self.apply_overridings()

        self.__parent = None

        super(Container, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        cdef Container copied

        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = <Container> _memorized_duplicate(self, memo)
        copied.__container_cls = self.__container_cls
        copied.__container = deepcopy(self.__container, memo)
        copied.__overriding_providers = deepcopy(self.__overriding_providers, memo)
        self._copy_parent(copied, memo)
        self._copy_overridings(copied, memo)
        return copied

    def __getattr__(self, name):
        """Return dependency provider."""
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(
                "'{cls}' object has no attribute "
                "'{attribute_name}'".format(cls=self.__class__.__name__, attribute_name=name))
        return getattr(self.__container, name)

    @property
    def providers(self):
        return self.__container.providers

    @property
    def container(self):
        return self.__container

    def override(self, provider):
        """Override provider with another provider."""
        if not hasattr(provider, "providers"):
            raise Error("Container provider {0} can be overridden only by providers container".format(self))

        self.__container.override_providers(**provider.providers)
        return super().override(provider)

    def reset_last_overriding(self):
        """Reset last overriding provider.

        :raise: :py:exc:`dependency_injector.errors.Error` if provider is not
                overridden.

        :rtype: None
        """
        super().reset_last_overriding()
        for provider in self.__container.providers.values():
            if not provider.overridden:
                continue
            provider.reset_last_overriding()

    def reset_override(self):
        """Reset all overriding providers.

        :rtype: None
        """
        super().reset_override()
        for provider in self.__container.providers.values():
            if not provider.overridden:
                continue
            provider.reset_override()

    def apply_overridings(self):
        """Apply container overriding.

        This method should not be called directly. It is called on
        declarative container initialization."""
        self.__container.override_providers(**self.__overriding_providers)

    @property
    def related(self):
        """Return related providers generator."""
        yield from self.providers.values()
        yield from super().related

    def resolve_provider_name(self, provider):
        """Try to resolve provider name."""
        for provider_name, container_provider in self.providers.items():
            if container_provider is provider:
                return provider_name
        else:
            raise Error(f"Can not resolve name for provider \"{provider}\"")

    @property
    def parent(self):
        """Return parent."""
        return self.__parent

    @property
    def parent_name(self):
        """Return parent name."""
        if not self.__parent:
            return None

        name = ""
        if self.__parent.parent_name:
            name += f"{self.__parent.parent_name}."
        name += f"{self.__parent.resolve_provider_name(self)}"

        return name

    def assign_parent(self, parent):
        """Assign parent."""
        self.__parent = parent

    def _copy_parent(self, copied, memo):
        _copy_parent(self, copied, memo)

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return single instance."""
        return self.__container


cdef class Selector(Provider):
    """Selector provider selects provider based on the configuration value or other callable.

    :py:class:`Selector` provider has a callable called ``selector`` and a dictionary of providers.

    The ``selector`` callable is provided as a first positional argument. It can be
    :py:class:`Configuration` provider or any other callable. It has to return a string value.
    That value is used as a key for selecting the provider from the dictionary of providers.

    The providers are provided as keyword arguments. Argument name is used as a key for
    selecting the provider.

    .. code-block:: python

        config = Configuration()

        selector = Selector(
            config.one_or_another,
            one=providers.Factory(SomeClass),
            another=providers.Factory(SomeOtherClass),
        )

        config.override({"one_or_another": "one"})
        instance_1 = selector()
        assert isinstance(instance_1, SomeClass)

        config.override({"one_or_another": "another"})
        instance_2 = selector()
        assert isinstance(instance_2, SomeOtherClass)
    """

    def __init__(self, selector=None, **providers):
        """Initialize provider."""
        self.__selector = None
        self.set_selector(selector)

        self.__providers = {}
        self.set_providers(**providers)

        super(Selector, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_selector(deepcopy(self.__selector, memo))
        copied.set_providers(**deepcopy(self.__providers, memo))

        self._copy_overridings(copied, memo)

        return copied

    def __getattr__(self, name):
        """Return provider."""
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(
                "'{cls}' object has no attribute "
                "'{attribute_name}'".format(cls=self.__class__.__name__, attribute_name=name))
        if name not in self.__providers:
            raise AttributeError("Selector has no \"{0}\" provider".format(name))

        return self.__providers[name]

    def __str__(self):
        """Return string representation of provider.

        :rtype: str
        """

        return "<{provider}({selector}, {providers}) at {address}>".format(
            provider=".".join(( self.__class__.__module__, self.__class__.__name__)),
            selector=self.__selector,
            providers=", ".join((
                "{0}={1}".format(name, provider)
                for name, provider in self.__providers.items()
            )),
            address=hex(id(self)),
        )

    @property
    def selector(self):
        """Return selector."""
        return self.__selector

    def set_selector(self, selector):
        """Set selector."""
        self.__selector = selector
        return self

    @property
    def providers(self):
        """Return providers."""
        return dict(self.__providers)

    def set_providers(self, **providers: Provider):
        """Set providers."""
        self.__providers = providers
        return self

    @property
    def related(self):
        """Return related providers generator."""
        yield from filter(is_provider, [self.__selector])
        yield from self.providers.values()
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        """Return single instance."""
        selector_value = self.__selector()

        if selector_value is None:
            raise Error("Selector value is undefined")

        if selector_value not in self.__providers:
            raise Error("Selector has no \"{0}\" provider".format(selector_value))

        return self.__providers[selector_value](*args, **kwargs)


cdef class ProvidedInstance(Provider):
    """Provider that helps to inject attributes and items of the injected instance.

    You can use it like that:

    .. code-block:: python

       service = providers.Singleton(Service)

       client_factory = providers.Factory(
           Client,
           value1=service.provided[0],
           value2=service.provided.value,
           value3=service.provided.values[0],
           value4=service.provided.get_value.call(),
       )

    You should not create this provider directly. Get it from the ``.provided`` attribute of the
    injected provider. This attribute returns the :py:class:`ProvidedInstance` for that provider.

    Providers that have ``.provided`` attribute:

    - :py:class:`Callable` and its subclasses
    - :py:class:`Factory` and its subclasses
    - :py:class:`Singleton` and its subclasses
    - :py:class:`Object`
    - :py:class:`List`
    - :py:class:`Selector`
    - :py:class:`Dependency`
    """

    def __init__(self, provides=None):
        self.__provides = None
        self.set_provides(provides)
        super().__init__()

    def __repr__(self):
        return f"{self.__class__.__name__}(\"{self.__provides}\")"

    def __deepcopy__(self, memo):
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_provides(_copy_if_provider(self.provides, memo))
        return copied

    def __getattr__(self, item):
        return AttributeGetter(self, item)

    def __getitem__(self, item):
        return ItemGetter(self, item)

    @property
    def provides(self):
        """Return provider provides."""
        return self.__provides

    def set_provides(self, provides):
        """Set provider provides."""
        self.__provides = provides
        return self

    def call(self, *args, **kwargs):
        return MethodCaller(self, *args, **kwargs)

    @property
    def related(self):
        """Return related providers generator."""
        if is_provider(self.provides):
            yield self.provides
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        return self.__provides(*args, **kwargs)


cdef class AttributeGetter(Provider):
    """Provider that returns the attribute of the injected instance.

    You should not create this provider directly. See :py:class:`ProvidedInstance` instead.
    """

    def __init__(self, provides=None, name=None):
        self.__provides = None
        self.set_provides(provides)

        self.__name = None
        self.set_name(name)
        super().__init__()

    def __repr__(self):
        return f"{self.__class__.__name__}(\"{self.name}\")"

    def __deepcopy__(self, memo):
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_provides(_copy_if_provider(self.provides, memo))
        copied.set_name(self.name)
        return copied

    def __getattr__(self, item):
        return AttributeGetter(self, item)

    def __getitem__(self, item):
        return ItemGetter(self, item)

    @property
    def provides(self):
        """Return provider provides."""
        return self.__provides

    def set_provides(self, provides):
        """Set provider provides."""
        self.__provides = provides
        return self

    @property
    def name(self):
        """Return name of the attribute."""
        return self.__name

    def set_name(self, name):
        """Set name of the attribute."""
        self.__name = name
        return self

    def call(self, *args, **kwargs):
        return MethodCaller(self, *args, **kwargs)

    @property
    def related(self):
        """Return related providers generator."""
        if is_provider(self.provides):
            yield self.provides
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        provided = self.provides(*args, **kwargs)
        if __is_future_or_coroutine(provided):
            future_result = asyncio.Future()
            provided = asyncio.ensure_future(provided)
            provided.add_done_callback(functools.partial(self._async_provide, future_result))
            return future_result
        return getattr(provided, self.name)

    def _async_provide(self, future_result, future):
        try:
            provided = future.result()
            result = getattr(provided, self.name)
        except Exception as exception:
            future_result.set_exception(exception)
        else:
            future_result.set_result(result)


cdef class ItemGetter(Provider):
    """Provider that returns the item of the injected instance.

    You should not create this provider directly. See :py:class:`ProvidedInstance` instead.
    """

    def __init__(self, provides=None, name=None):
        self.__provides = None
        self.set_provides(provides)

        self.__name = None
        self.set_name(name)
        super().__init__()

    def __repr__(self):
        return f"{self.__class__.__name__}(\"{self.name}\")"

    def __deepcopy__(self, memo):
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_provides(_copy_if_provider(self.provides, memo))
        copied.set_name(self.name)
        return copied

    def __getattr__(self, item):
        return AttributeGetter(self, item)

    def __getitem__(self, item):
        return ItemGetter(self, item)

    @property
    def provides(self):
        """Return provider"s provides."""
        return self.__provides

    def set_provides(self, provides):
        """Set provider"s provides."""
        self.__provides = provides
        return self

    @property
    def name(self):
        """Return name of the item."""
        return self.__name

    def set_name(self, name):
        """Set name of the item."""
        self.__name = name
        return self

    def call(self, *args, **kwargs):
        return MethodCaller(self, *args, **kwargs)

    @property
    def related(self):
        """Return related providers generator."""
        if is_provider(self.provides):
            yield self.provides
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        provided = self.provides(*args, **kwargs)
        if __is_future_or_coroutine(provided):
            future_result = asyncio.Future()
            provided = asyncio.ensure_future(provided)
            provided.add_done_callback(functools.partial(self._async_provide, future_result))
            return future_result
        return provided[self.name]

    def _async_provide(self, future_result, future):
        try:
            provided = future.result()
            result = provided[self.name]
        except Exception as exception:
            future_result.set_exception(exception)
        else:
            future_result.set_result(result)


cdef class MethodCaller(Provider):
    """Provider that calls the method of the injected instance.

    You should not create this provider directly. See :py:class:`ProvidedInstance` instead.
    """

    def __init__(self, provides=None, *args, **kwargs):
        self.__provides = None
        self.set_provides(provides)

        self.__args = tuple()
        self.__args_len = 0
        self.set_args(*args)

        self.__kwargs = tuple()
        self.__kwargs_len = 0
        self.set_kwargs(**kwargs)

        super().__init__()

    def __repr__(self):
        return f"{self.__class__.__name__}({self.provides})"

    def __deepcopy__(self, memo):
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = _memorized_duplicate(self, memo)
        copied.set_provides(_copy_if_provider(self.provides, memo))
        copied.set_args(*deepcopy(self.args, memo))
        copied.set_kwargs(**deepcopy(self.kwargs, memo))
        self._copy_overridings(copied, memo)
        return copied

    def __getattr__(self, item):
        return AttributeGetter(self, item)

    def __getitem__(self, item):
        return ItemGetter(self, item)

    def call(self, *args, **kwargs):
        return MethodCaller(self, *args, **kwargs)

    @property
    def provides(self):
        """Return provider provides."""
        return self.__provides

    def set_provides(self, provides):
        """Set provider provides."""
        self.__provides = provides
        return self

    @property
    def args(self):
        """Return positional argument injections."""
        cdef int index
        cdef PositionalInjection arg
        cdef list args

        args = list()
        for index in range(self.__args_len):
            arg = self.__args[index]
            args.append(arg.__value)
        return tuple(args)

    def set_args(self, *args):
        """Set positional argument injections.

        Existing positional argument injections are dropped.

        :return: Reference ``self``
        """
        self.__args = parse_positional_injections(args)
        self.__args_len = len(self.__args)
        return self

    @property
    def kwargs(self):
        """Return keyword argument injections."""
        cdef int index
        cdef NamedInjection kwarg
        cdef dict kwargs

        kwargs = dict()
        for index in range(self.__kwargs_len):
            kwarg = self.__kwargs[index]
            kwargs[kwarg.__name] = kwarg.__value
        return kwargs

    def set_kwargs(self, **kwargs):
        """Set keyword argument injections.

        Existing keyword argument injections are dropped.

        :return: Reference ``self``
        """
        self.__kwargs = parse_named_injections(kwargs)
        self.__kwargs_len = len(self.__kwargs)
        return self

    @property
    def related(self):
        """Return related providers generator."""
        if is_provider(self.provides):
            yield self.provides
        yield from filter(is_provider, self.args)
        yield from filter(is_provider, self.kwargs.values())
        yield from super().related

    cpdef object _provide(self, tuple args, dict kwargs):
        call = self.provides()
        if __is_future_or_coroutine(call):
            future_result = asyncio.Future()
            call = asyncio.ensure_future(call)
            call.add_done_callback(functools.partial(self._async_provide, future_result, args, kwargs))
            return future_result
        return __call(
            call,
            args,
            self.__args,
            self.__args_len,
            kwargs,
            self.__kwargs,
            self.__kwargs_len,
            self.__async_mode,
        )

    def _async_provide(self, future_result, args, kwargs, future):
        try:
            call = future.result()
            result = __call(
                call,
                args,
                self.__args,
                self.__args_len,
                kwargs,
                self.__kwargs,
                self.__kwargs_len,
                self.__async_mode,
            )
        except Exception as exception:
            future_result.set_exception(exception)
        else:
            future_result.set_result(result)


cdef class Injection(object):
    """Abstract injection class."""


cdef class PositionalInjection(Injection):
    """Positional injection class."""

    def __init__(self, value=None):
        """Initializer."""
        self.__value = None
        self.__is_provider = 0
        self.__is_delegated = 0
        self.__call = 0
        self.set(value)
        super(PositionalInjection, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied
        copied = _memorized_duplicate(self, memo)
        copied.set(_copy_if_provider(self.__value, memo))
        return copied

    def get_value(self):
        """Return injection value."""
        return __get_value(self)

    def get_original_value(self):
        """Return original value."""
        return self.__value

    def set(self, value):
        """Set injection."""
        self.__value = value
        self.__is_provider = <int>is_provider(value)
        self.__is_delegated = <int>is_delegated(value)
        self.__call = <int>(self.__is_provider == 1 and self.__is_delegated == 0)


cdef class NamedInjection(Injection):
    """Keyword injection class."""

    def __init__(self, name=None, value=None):
        """Initializer."""
        self.__name = name
        self.set_name(name)

        self.__value = None
        self.__is_provider = 0
        self.__is_delegated = 0
        self.__call = 0
        self.set(value)

        super(NamedInjection, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of provider."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied
        copied = _memorized_duplicate(self, memo)
        copied.set_name(self.get_name())
        copied.set(_copy_if_provider(self.__value, memo))
        return copied

    def get_name(self):
        """Return injection name."""
        return __get_name(self)

    def set_name(self, name):
        """Set injection name."""
        self.__name = name

    def get_value(self):
        """Return injection value."""
        return __get_value(self)

    def get_original_value(self):
        """Return original value."""
        return self.__value

    def set(self, value):
        """Set injection."""
        self.__value = value
        self.__is_provider = <int>is_provider(value)
        self.__is_delegated = <int>is_delegated(value)
        self.__call = <int>(self.__is_provider == 1 and self.__is_delegated == 0)


@cython.boundscheck(False)
@cython.wraparound(False)
cpdef tuple parse_positional_injections(tuple args):
    """Parse positional injections."""
    cdef list injections = list()
    cdef int args_len = len(args)

    cdef int index
    cdef object arg
    cdef PositionalInjection injection

    for index in range(args_len):
        arg = args[index]
        injection = PositionalInjection(arg)
        injections.append(injection)

    return tuple(injections)


@cython.boundscheck(False)
@cython.wraparound(False)
cpdef tuple parse_named_injections(dict kwargs):
    """Parse named injections."""
    cdef list injections = list()

    cdef object name
    cdef object arg
    cdef NamedInjection injection

    for name, arg in kwargs.items():
        injection = NamedInjection(name, arg)
        injections.append(injection)

    return tuple(injections)


cdef class OverridingContext(object):
    """Provider overriding context.

    :py:class:`OverridingContext` is used by :py:meth:`Provider.override` for
    implementing ``with`` contexts. When :py:class:`OverridingContext` is
    closed, overriding that was created in this context is dropped also.

    .. code-block:: python

        with provider.override(another_provider):
            assert provider.overridden
        assert not provider.overridden
    """

    def __init__(self, Provider overridden, Provider overriding):
        """Initializer.

        :param overridden: Overridden provider.
        :type overridden: :py:class:`Provider`

        :param overriding: Overriding provider.
        :type overriding: :py:class:`Provider`
        """
        self.__overridden = overridden
        self.__overriding = overriding
        super(OverridingContext, self).__init__()

    def __enter__(self):
        """Do nothing."""
        return self.__overriding

    def __exit__(self, *_):
        """Exit overriding context."""
        self.__overridden.reset_last_overriding()


cdef class BaseSingletonResetContext(object):

    def __init__(self, Provider provider):
        self.__singleton = provider
        super().__init__()

    def __enter__(self):
        return self.__singleton

    def __exit__(self, *_):
        raise NotImplementedError()


cdef class SingletonResetContext(BaseSingletonResetContext):

    def __exit__(self, *_):
        return self.__singleton.reset()


cdef class SingletonFullResetContext(BaseSingletonResetContext):

    def __exit__(self, *_):
        return self.__singleton.full_reset()


CHILD_PROVIDERS = (Dependency, DependenciesContainer, Container)


cpdef bint is_provider(object instance):
    """Check if instance is provider instance.

    :param instance: Instance to be checked.
    :type instance: object

    :rtype: bool
    """
    return (not isinstance(instance, CLASS_TYPES) and
            getattr(instance, "__IS_PROVIDER__", False) is True)


cpdef object ensure_is_provider(object instance):
    """Check if instance is provider instance and return it.

    :param instance: Instance to be checked.
    :type instance: object

    :raise: :py:exc:`dependency_injector.errors.Error` if provided instance is
            not provider.

    :rtype: :py:class:`dependency_injector.providers.Provider`
    """
    if not is_provider(instance):
        raise Error("Expected provider instance, got {0}".format(str(instance)))
    return instance


cpdef bint is_delegated(object instance):
    """Check if instance is delegated provider.

    :param instance: Instance to be checked.
    :type instance: object

    :rtype: bool
    """
    return (not isinstance(instance, CLASS_TYPES) and
            getattr(instance, "__IS_DELEGATED__", False) is True)


cpdef str represent_provider(object provider, object provides):
    """Return string representation of provider.

    :param provider: Provider object
    :type provider: :py:class:`dependency_injector.providers.Provider`

    :param provides: Object that provider provides
    :type provider: object

    :return: String representation of provider
    :rtype: str
    """
    return "<{provider}({provides}) at {address}>".format(
        provider=".".join((provider.__class__.__module__,
                           provider.__class__.__name__)),
        provides=repr(provides) if provides is not None else "",
        address=hex(id(provider)))


cpdef bint is_container_instance(object instance):
    """Check if instance is container instance.

    :param instance: Instance to be checked.
    :type instance: object

    :rtype: bool
    """
    return (not isinstance(instance, CLASS_TYPES) and
            getattr(instance, "__IS_CONTAINER__", False) is True)


cpdef bint is_container_class(object instance):
    """Check if instance is container class.

    :param instance: Instance to be checked.
    :type instance: object

    :rtype: bool
    """
    return (isinstance(instance, CLASS_TYPES) and
            getattr(instance, "__IS_CONTAINER__", False) is True)


cpdef object deepcopy(object instance, dict memo=None):
    """Return full copy of provider or container with providers."""
    if memo is None:
        memo = dict()

    __add_sys_streams(memo)

    return copy.deepcopy(instance, memo)


def __add_sys_streams(memo):
    """Add system streams to memo dictionary.

    This helps to avoid copying of system streams while making a deepcopy of
    objects graph.
    """
    memo[id(sys.stdin)] = sys.stdin
    memo[id(sys.stdout)] = sys.stdout
    memo[id(sys.stderr)] = sys.stderr


def merge_dicts(dict1, dict2):
    """Merge dictionaries recursively.

    :param dict1: Dictionary 1
    :type dict1: dict

    :param dict2: Dictionary 2
    :type dict2: dict

    :return: New resulting dictionary
    :rtype: dict
    """
    for key, value in dict1.items():
        if key in dict2:
            if isinstance(value, dict) and isinstance(dict2[key], dict):
                dict2[key] = merge_dicts(value, dict2[key])
    result = dict1.copy()
    result.update(dict2)
    return result


def traverse(*providers, types=None):
    """Return providers traversal generator."""
    visited = set()
    to_visit = set(providers)

    if types:
        types = tuple(types)

    while len(to_visit) > 0:
        visiting = to_visit.pop()
        visited.add(visiting)

        for child in visiting.related:
            if child in visited:
                continue
            to_visit.add(child)

        if types and not isinstance(visiting, types):
            continue

        yield visiting


def isawaitable(obj):
    """Check if object is a coroutine function."""
    try:
        return inspect.isawaitable(obj)
    except AttributeError:
        return False


def iscoroutinefunction(obj):
    """Check if object is a coroutine function."""
    try:
        return inspect.iscoroutinefunction(obj)
    except AttributeError:
        return False


def isasyncgenfunction(obj):
    """Check if object is an asynchronous generator function."""
    try:
        return inspect.isasyncgenfunction(obj)
    except AttributeError:
        return False


def _resolve_string_import(provides):
    if provides is None:
        return provides

    if not isinstance(provides, str):
        return provides

    segments = provides.split(".")
    member_name = segments[-1]

    if len(segments) == 1:
        if  member_name in dir(builtins):
            module = builtins
        else:
            module = _resolve_calling_module()
        return getattr(module, member_name)

    module_name = ".".join(segments[:-1])

    package_name = _resolve_calling_package_name()
    if module_name.startswith(".") and package_name is None:
        raise ImportError("Attempted relative import with no known parent package")

    module = importlib.import_module(module_name, package=package_name)
    return getattr(module, member_name)


def _resolve_calling_module():
    stack = inspect.stack()
    pre_last_frame = stack[0]
    return inspect.getmodule(pre_last_frame[0])


def _resolve_calling_package_name():
    module = _resolve_calling_module()
    return module.__package__


cpdef _copy_parent(object from_, object to, dict memo):
    """Copy and assign provider parent."""
    copied_parent = (
        deepcopy(from_.parent, memo)
        if is_provider(from_.parent) or is_container_instance(from_.parent)
        else from_.parent
    )
    to.assign_parent(copied_parent)


cpdef object _memorized_duplicate(object instance, dict memo):
    copied = instance.__class__()
    memo[id(instance)] = copied
    return copied


cpdef object _copy_if_provider(object instance, dict memo):
    if not is_provider(instance):
        return instance
    return deepcopy(instance, memo)


cpdef str _class_qualname(object instance):
    name = getattr(instance.__class__, "__qualname__", None)
    if not name:
        name = ".".join((instance.__class__.__module__, instance.__class__.__name__))
    return name
