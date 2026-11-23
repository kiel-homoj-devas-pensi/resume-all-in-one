"""存储和管理脚本导入包时不启动 HTTP 服务。"""

__all__ = ["createApplication"]


def __getattr__(name: str) -> object:
    if name not in __all__:
        raise AttributeError(name)
    from .app import createApplication

    globals()["createApplication"] = createApplication
    return globals()[name]
