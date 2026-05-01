# 编译器编写之旅（A Compiler Writing Journey）

在这个 Github 仓库里，我记录了自己编写一个可自举的编译器的过程。
这个编译器面向 C 语言的一个子集，并且最终能够编译自己。
我也会把过程中的细节一并写出来，这样如果你想跟着一起做，
就能看到我做了什么、为什么这么做，以及它和编译器理论之间有哪些联系。

不过理论不会讲得太多，我更希望这是一段偏实践的旅程。

下面是我目前已经完成的各个步骤：

 + [第 0 部分](00_Introduction/Readme.md)：旅程介绍
 + [第 1 部分](01_Scanner/Readme.md)：词法扫描（Lexical Scanning）简介
 + [第 2 部分](02_Parser/Readme.md)：语法解析（Parsing）简介
 + [第 3 部分](03_Precedence/Readme.md)：运算符优先级
 + [第 4 部分](04_Assembly/Readme.md)：一个真正的编译器
 + [第 5 部分](05_Statements/Readme.md)：语句
 + [第 6 部分](06_Variables/Readme.md)：变量
 + [第 7 部分](07_Comparisons/Readme.md)：比较运算符
 + [第 8 部分](08_If_Statements/Readme.md)：`if` 语句
 + [第 9 部分](09_While_Loops/Readme.md)：`while` 循环
 + [第 10 部分](10_For_Loops/Readme.md)：`for` 循环
 + [第 11 部分](11_Functions_pt1/Readme.md)：函数，第 1 部分
 + [第 12 部分](12_Types_pt1/Readme.md)：类型，第 1 部分
 + [第 13 部分](13_Functions_pt2/Readme.md)：函数，第 2 部分
 + [第 14 部分](14_ARM_Platform/Readme.md)：生成 ARM 汇编代码
 + [第 15 部分](15_Pointers_pt1/Readme.md)：指针，第 1 部分
 + [第 16 部分](16_Global_Vars/Readme.md)：正确声明全局变量
 + [第 17 部分](17_Scaling_Offsets/Readme.md)：更好的类型检查与指针偏移
 + [第 18 部分](18_Lvalues_Revisited/Readme.md)：重新审视左值与右值
 + [第 19 部分](19_Arrays_pt1/Readme.md)：数组，第 1 部分
 + [第 20 部分](20_Char_Str_Literals/Readme.md)：字符与字符串字面量
 + [第 21 部分](21_More_Operators/Readme.md)：更多运算符
 + [第 22 部分](22_Design_Locals/Readme.md)：局部变量与函数调用的设计思路
 + [第 23 部分](23_Local_Variables/Readme.md)：局部变量
 + [第 24 部分](24_Function_Params/Readme.md)：函数参数
 + [第 25 部分](25_Function_Arguments/Readme.md)：函数调用与实参
 + [第 26 部分](26_Prototypes/Readme.md)：函数原型
 + [第 27 部分](27_Testing_Errors/Readme.md)：回归测试与一个惊喜
 + [第 28 部分](28_Runtime_Flags/Readme.md)：增加更多运行时标志
 + [第 29 部分](29_Refactoring/Readme.md)：做一点重构
 + [第 30 部分](30_Design_Composites/Readme.md)：设计结构体、联合体与枚举
 + [第 31 部分](31_Struct_Declarations/Readme.md)：实现结构体，第 1 部分
 + [第 32 部分](32_Struct_Access_pt1/Readme.md)：访问结构体成员
 + [第 33 部分](33_Unions/Readme.md)：实现联合体与成员访问
 + [第 34 部分](34_Enums_and_Typedefs/Readme.md)：枚举与 typedef
 + [第 35 部分](35_Preprocessor/Readme.md)：C 预处理器（Pre-Processor）
 + [第 36 部分](36_Break_Continue/Readme.md)：`break` 与 `continue`
 + [第 37 部分](37_Switch/Readme.md)：`switch` 语句
 + [第 38 部分](38_Dangling_Else/Readme.md)：悬空 `else` 与更多内容
 + [第 39 部分](39_Var_Initialisation_pt1/Readme.md)：变量初始化，第 1 部分
 + [第 40 部分](40_Var_Initialisation_pt2/Readme.md)：全局变量初始化
 + [第 41 部分](41_Local_Var_Init/Readme.md)：局部变量初始化
 + [第 42 部分](42_Casting/Readme.md)：类型转换与 NULL
 + [第 43 部分](43_More_Operators/Readme.md)：Bug 修复与更多运算符
 + [第 44 部分](44_Fold_Optimisation/Readme.md)：常量折叠
 + [第 45 部分](45_Globals_Again/Readme.md)：再次讨论全局变量声明
 + [第 46 部分](46_Void_Functions/Readme.md)：`void` 函数参数与扫描器修改
 + [第 47 部分](47_Sizeof/Readme.md)：`sizeof` 的一个子集
 + [第 48 部分](48_Static/Readme.md)：`static` 的一个子集
 + [第 49 部分](49_Ternary/Readme.md)：三元运算符
 + [第 50 部分](50_Mop_up_pt1/Readme.md)：收尾工作，第 1 部分
 + [第 51 部分](51_Arrays_pt2/Readme.md)：数组，第 2 部分
 + [第 52 部分](52_Pointers_pt2/Readme.md)：指针，第 2 部分
 + [第 53 部分](53_Mop_up_pt2/Readme.md)：收尾工作，第 2 部分
 + [第 54 部分](54_Reg_Spills/Readme.md)：寄存器溢出到内存
 + [第 55 部分](55_Lazy_Evaluation/Readme.md)：惰性求值
 + [第 56 部分](56_Local_Arrays/Readme.md)：局部数组
 + [第 57 部分](57_Mop_up_pt3/Readme.md)：收尾工作，第 3 部分
 + [第 58 部分](58_Ptr_Increments/Readme.md)：修正指针的自增与自减
 + [第 59 部分](59_WDIW_pt1/Readme.md)：为什么它不工作，第 1 部分
 + [第 60 部分](60_TripleTest/Readme.md)：通过三重测试
 + [第 61 部分](61_What_Next/Readme.md)：接下来做什么？
 + [第 62 部分](62_Cleanup/Readme.md)：代码清理
 + [第 63 部分](63_QBE/Readme.md)：使用 QBE 的新后端
 + [第 64 部分](64_6809_Target/Readme.md)：面向 6809 CPU 的后端

我已经停止维护 *acwj*，目前正在从零开始编写一门新语言
[alic](https://github.com/DoctorWkt/alic)，欢迎看看。

## 版权说明

我借用了 [SubC](http://www.t3x.org/subc/) 编译器中的部分代码以及很多思路，
它的作者是 Nils M Holm。
他的代码属于公有领域。我认为我的代码已经有了足够大的差异，
因此可以使用不同的许可证发布。

除非另有说明：

 + 所有源代码和脚本均为 Warren Toomey 版权所有，采用 GPL3 许可证。
 + 所有非源代码文档（例如英文文档、图片文件）均为 Warren Toomey 版权所有，
   采用 Creative Commons BY-NC-SA 4.0 许可证。
