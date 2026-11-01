"""Every route the app really serves, with its full path. FastAPI 0.162 keeps an included router's
routes behind one wrapper in app.routes, so walking app.routes for APIRoute alone silently misses
them; this uses FastAPI's public iter_route_contexts, which yields each effective route."""

from dataclasses import dataclass

from fastapi import FastAPI
from fastapi.routing import iter_route_contexts


@dataclass(frozen=True)
class ServedRoute:
    method: str
    path: str
    body_types: tuple[object, ...]


def served_routes(app: FastAPI) -> list[ServedRoute]:
    routes = []
    for context in iter_route_contexts(app.routes):
        methods = getattr(context, "methods", None) or ()
        dependant = getattr(context, "dependant", None)
        body = tuple(p.field_info.annotation for p in dependant.body_params) if dependant else ()
        path = context.path
        assert path is not None, f"a served route without a path would escape the guards: {context}"
        routes.extend(ServedRoute(method, path, body) for method in methods)
    return routes
