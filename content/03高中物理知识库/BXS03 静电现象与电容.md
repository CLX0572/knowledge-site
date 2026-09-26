
---

## 电容的动态分析问题

### 知识点

核心是以下三个公式的联立：

- **定义式**：   $$ C = \frac{Q}{U} $$  
  （任何电容器都适用，C 由自身结构决定）

- **平行板决定式**：  
  $$ C = \frac{\varepsilon_r S}{4\pi k d} $$  
  （$S$ 正对面积，$d$ 板间距，$\varepsilon_r$ 相对介电常数）

- **场强关联式**（匀强电场）：  
  $$ E = \frac{U}{d} $$

## 常见物理量分析过程

S1: 基本条件确定：找不变量

① 始终与电源相连（开关闭合）：不变量为电压 $U$（等于电源电动势）  
② 充电后断开电源（开关断开）：不变物理量为电荷量 $Q$

S2：
- **分析路径**：  
  改变 $S, d, \varepsilon$ → 由决定式判 $C$ 变 → 由 $U = Q/C$ 判 $U$ 变 → **$E$ 不可直接用 $U/d$**，而是：  
  $$ E = \frac{U}{d} = \frac{Q}{Cd} = \frac{4\pi k Q}{\varepsilon_r S} $$


  改变 $S, d, \varepsilon$ → 由 $C = \frac{\varepsilon_r S}{4\pi k d}$ 判 $C$ 变 → 由 $Q = CU$ 判 $Q$ 变 → 由 $E = U/d$ 判 $E$ 变

  
  得出黄金结论：**$Q$ 不变时，$E$ 只由 $S$ 和 $\varepsilon_r$ 决定，与 $d$ 无关！**


## 3. 常见变量操作结果汇总（高频速查表）

| 操作                                  | 若 **U 不变**（不断电源）                                          | 若 **Q 不变**（断电源）                                           |
| :---------------------------------- | :-------------------------------------------------------- | :-------------------------------------------------------- |
| **增大板距 $d$**                        | $C \downarrow$，$Q \downarrow$（放电），$E \downarrow$          | $C \downarrow$，$U \uparrow$，**$E$ 不变** ★                  |
| **减小板距 $d$**                        | $C \uparrow$，$Q \uparrow$（充电），$E \uparrow$                | $C \uparrow$，$U \downarrow$，**$E$ 不变** ★                  |
| **增大正对面积 $S$**                      | $C \uparrow$，$Q \uparrow$，$E$ 不变                          | $C \uparrow$，$U \downarrow$，**$E \downarrow$**            |
| **插入介质板**（$\varepsilon_r \uparrow$） | $C \uparrow$，$Q \uparrow$，$E$ 不变                          | $C \uparrow$，$U \downarrow$，**$E \downarrow$**            |
| **插入金属板**                           | 等效于 $d \downarrow$：$C \uparrow$，$Q \uparrow$，$E \uparrow$ | 等效于 $d \downarrow$：$C \uparrow$，$U \downarrow$，**$E$ 不变** |
|                                     |                                                           |                                                           |


## 4. 解题“三步走” SOP
遇到具体题目，严格按以下步骤下笔：

1. **判状态**：看开关，确定 $U$ 恒定还是 $Q$ 恒定。  
2. **判电容**：看题干动了哪个参数（$S, d, \varepsilon$），用 $C \propto \frac{S}{d}$ 判断 $C$ 变向。  
3. **判待求量**：  
   - 若 $U$ 恒定：$Q = CU$，$E = U/d$。  
   - 若 $Q$ 恒定：$U = Q/C$，$E \propto \frac{1}{\varepsilon S}$（避开 $d$）。


## 5. 易错陷阱 & 进阶思维（拉分关键）

- **陷阱 1**：$E$ 并非总是与 $d$ 成反比。  
  ✅ 只有 **$U$ 不变** 时，$E \propto 1/d$；**$Q$ 不变** 时，$E$ 与 $d$ 无关。

- **陷阱 2**：有二极管时，不能直接套 $U$ 或 $Q$ 恒定。  
  ✅ 先判断电流方向：若电容要放电但二极管阻止，则 $Q$ 不变；若充电，则 $U$ 会随电源变化。

- **进阶 1（受力/偏角）**：若悬吊小球偏角 $\theta$，因 $\tan\theta \propto E$。  
  若 $Q$ 不变且仅改变 $d$，则 $E$ 不变 → 偏角 $\underline{\text{不变}}$（极易误判）。

- **进阶 2（运动/加速度）**：粒子在板间运动，$a = qE/m$，直接盯住 $E$ 的变化即可。


## 6. 实战演练（检验掌握度）

> **题目**：平行板电容器充电后与电源断开，负极板接地，正极板不动，将负极板向上移动（即减小 $d$）。  
> **问**：(1) 板间场强 $E$ 如何变？ (2) P 点（固定在上板附近某点）电势 $\varphi_P$ 如何变？

**【解析】**  
1. 断开电源 → **$Q$ 不变**。  
2. $d$ 减小 → 由 $C = \frac{\varepsilon_r S}{4\pi k d}$ 得 $C \uparrow$。  
3. 由 $E = \frac{4\pi k Q}{\varepsilon_r S}$ 得 **$E$ 不变**。  
4. 负极板接地（电势为 0），P 到负极板距离 $d_{P下}$ 减小，而 $U_{P下} = E \cdot d_{P下}$，故 $U_{P下} \downarrow$，因此 **$\varphi_P = E \cdot d_{P下}$ 变小**。
