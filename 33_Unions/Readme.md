# 第 33 部分：实现 union 与成员访问

union 之所以也很容易实现，
核心原因只有一个：
它几乎就像 struct，
只是 union 的所有成员都位于“相对于 union 基址偏移 0”的位置。
另外，
union 声明的语法和 struct 声明也完全一样，
除了关键字从 `struct` 换成了 `union`。

这意味着，
我们完全可以重用并稍作修改现有的 struct 代码，
来处理 union。

## 一个新关键字：`union`

我已经在 `scan.c` 中把关键字 `union`
以及对应的 `T_UNION` token 加进扫描器了。
照例，
具体扫描代码我就不展开了。

## Union 符号链表

和 struct 一样，
我们也有一条单独的 union 链表
（位于 `data.h`）：

```c
extern_ struct symtable *Unionhead, *Uniontail;   // List of struct types
```

在 `sym.c` 中，
我还写了 `addunion()` 和 `findunion()`，
分别用于把新 union 类型节点加进这条链表，
以及在链表上按名字查找 union 类型。

> 我在考虑把 struct 和 union 两条链表合并成一条统一的复合类型链表，
  只是目前还没动手。
  大概率会放到下一次重构里再做。

## 解析 union 声明

我们接下来会修改 `decl.c` 中现有的 struct 解析代码，
让它同时能处理 struct 与 union。
这里我只给出变动部分，
不把整个函数全贴出来。

在 `parse_type()` 中，
现在我们会扫描 `T_UNION`，
并调用一个统一解析 struct / union 的函数：

```c
  case T_STRUCT:
    type = P_STRUCT;
    *ctype = composite_declaration(P_STRUCT);
    break;
  case T_UNION:
    type = P_UNION;
    *ctype = composite_declaration(P_UNION);
    break;
```

这个 `composite_declaration()`
在上一部分里还叫 `struct_declaration()`。
现在它会接收一个参数，
表示当前正在解析的是哪种复合类型。

## `composite_declaration()` 函数

下面是改动部分：

```c
// Parse composite type declarations: structs or unions.
// Either find an existing struct/union declaration, or build
// a struct/union symbol table entry and return its pointer.
static struct symtable *composite_declaration(int type) {
  ...
  // Find any matching composite type
  if (type == P_STRUCT)
    ctype = findstruct(Text);
  else
    ctype = findunion(Text);
  ...
  // Build the composite type and skip the left brace
  if (type == P_STRUCT)
    ctype = addstruct(Text, P_STRUCT, NULL, 0, 0);
  else
    ctype = addunion(Text, P_UNION, NULL, 0, 0);
  ...
  // Set the position of each successive member in the composite type
  // Unions are easy. For structs, align the member and find the next free byte
  for (m = m->next; m != NULL; m = m->next) {
    // Set the offset for this member
    if (type == P_STRUCT)
      m->posn = genalign(m->type, offset, 1);
    else
      m->posn = 0;

    // Get the offset of the next free byte after this member
    offset += typesize(m->type, m->ctype);
  }
  ...
  return (ctype);
}
```

差不多就是这样。
我们只不过是根据当前类型，
切换到对应的符号链表上工作，
并且在处理 union 时，
始终把成员偏移量设为 0。
这也正是我觉得“把 struct 和 union 类型链表合并成一条”
很值得考虑的原因。

## 解析 union 表达式

和 union 声明一样，
表达式中处理 union 的逻辑也基本可以直接复用 struct 的代码。
事实上，
`expr.c` 里需要改动的地方非常少。

```c
// Parse the member reference of a struct or union
// and return an AST tree for it. If withpointer is true,
// the access is through a pointer to the member.
static struct ASTnode *member_access(int withpointer) {
  ...
  if (withpointer && compvar->type != pointer_to(P_STRUCT)
      && compvar->type != pointer_to(P_UNION))
    fatals("Undeclared variable", Text);
  if (!withpointer && compvar->type != P_STRUCT && compvar->type != P_UNION)
    fatals("Undeclared variable", Text);
```

没错，
基本就这点改动。
其余代码原本就已经足够通用，
可以不做修改地直接服务于 union。
另外还有一处比较重要的变化，
是在 `types.c` 的一个函数里：

```c
// Given a type and a composite type pointer, return
// the size of this type in bytes
int typesize(int type, struct symtable *ctype) {
  if (type == P_STRUCT || type == P_UNION)
    return (ctype->size);
  return (genprimsize(type));
}
```

## 测试 union 代码

下面是我们的测试程序 `test/input62.c`：

```c
int printf(char *fmt);

union fred {
  char w;
  int  x;
  int  y;
  long z;
};

union fred var1;
union fred *varptr;

int main() {
  var1.x= 65; printf("%d\n", var1.x);
  var1.x= 66; printf("%d\n", var1.x); printf("%d\n", var1.y);
  printf("The next two depend on the endian of the platform\n");
  printf("%d\n", var1.w); printf("%d\n", var1.z);

  varptr= &var1; varptr->x= 67;
  printf("%d\n", varptr->x); printf("%d\n", varptr->y);

  return(0);
}
```

它会测试：
union 里的四个成员是否真的都位于同一位置，
从而使得“改一个成员”能通过另一个成员观察到相同的变化。
另外也顺带验证：
通过指针访问 union 成员是否同样工作。

## 总结与下一步

这又是编译器编写之旅里一个相对轻松的部分。
在下一部分中，
我们会加入 enum。 [下一步](../34_Enums_and_Typedefs/Readme.md)
