local L = Gargul_L;

---@type GL
local _, GL = ...;

GL.AceGUI = GL.AceGUI or LibStub("AceGUI-3.0");

local AceGUI = GL.AceGUI;

GL:tableSet(GL, "Interface.SoftRes.Importer", {
    isVisible = false,

    InterfaceItems = {
        Icons = {},
        Frames = {},
        Labels = {},
        Tables = {},
    },
});

local Importer = GL.Interface.SoftRes.Importer;

function Importer:draw()
    if (self.isVisible) then
        return;
    end

    self.isVisible = true;

    -- Create a container/parent frame
    local Window = AceGUI:Create("Frame");
    Window:SetTitle((L["Gargul v%s"]):format(GL.version));
    Window:SetLayout("Flow");
    Window:SetWidth(600);
    Window:SetHeight(580);
    Window:EnableResize(false);
    Window.statustext:GetParent():Hide(); -- Hide the statustext bar
    Window:SetCallback("OnClose", function ()
        self:close();
    end);
    GL.Interface:set(self, "Window", Window);

    Window:SetPoint(GL.Interface:getPosition("SoftReserveImport"));

    -- Make sure the window can be closed by pressing the escape button
    _G.GARGUL_SOFTRES_IMPORTER_WINDOW = Window.frame;
    tinsert(UISpecialFrames, "GARGUL_SOFTRES_IMPORTER_WINDOW");

    -- Explanation
    local Description = AceGUI:Create("Label");
    Description:SetFontObject(_G.GameFontNormal);
    Description:SetFullWidth(true);
    Description:SetText(L["In order to get started you first need to create a raid on softres.it. Afterwards click on 'Addon Export', select 'Gargul', copy the data and paste it in the form below."]);
    Window:AddChild(Description);

    -- Large edit box
    local softReservesBoxContent = "";
    local SoftResBox = AceGUI:Create("MultiLineEditBox");
    SoftResBox:SetFullWidth(true);
    SoftResBox:DisableButton(true);
    SoftResBox:SetFocus();
    SoftResBox:SetLabel("");
    SoftResBox:SetNumLines(14);
    SoftResBox:SetMaxLetters(999999999);
    Window:AddChild(SoftResBox);

    SoftResBox:SetCallback("OnTextChanged", function (_, _, text)
        softReservesBoxContent = text;
    end)

    -- Rolling SR extra rolls label
    local RollingSRLabel = AceGUI:Create("Label");
    RollingSRLabel:SetFontObject(_G.GameFontNormal);
    RollingSRLabel:SetFullWidth(true);
    RollingSRLabel:SetText("Rolling SR: Paste the Weekly Extra Rolls String below (optional):");
    Window:AddChild(RollingSRLabel);

    -- Rolling SR extra rolls input
    local rollingExtraRollsContent = GL.RollingSR and GL.RollingSR.rawImportString or "";
    local RollingSRBox = AceGUI:Create("MultiLineEditBox");
    RollingSRBox:SetFullWidth(true);
    RollingSRBox:DisableButton(true);
    RollingSRBox:SetLabel("");
    RollingSRBox:SetNumLines(4);
    RollingSRBox:SetMaxLetters(999999999);
    RollingSRBox:SetText(rollingExtraRollsContent);
    Window:AddChild(RollingSRBox);

    RollingSRBox:SetCallback("OnTextChanged", function (_, _, text)
        rollingExtraRollsContent = text;
    end)

    -- Status message frame
    local StatusMessageFrame = AceGUI:Create("SimpleGroup");
    StatusMessageFrame:SetLayout("FILL");
    StatusMessageFrame:SetWidth(570);
    StatusMessageFrame:SetHeight(56);
    Window:AddChild(StatusMessageFrame);

    local StatusMessageLabel = AceGUI:Create("Label");
    StatusMessageLabel:SetFontObject(_G.GameFontNormal);
    StatusMessageLabel:SetFullWidth(true);
    StatusMessageLabel:SetColor(1, 0, 0);
    StatusMessageFrame:AddChild(StatusMessageLabel);
    GL.Interface:set(self, "StatusMessage", StatusMessageLabel);

    -- Import button
    local ImportButton = AceGUI:Create("Button");
    ImportButton:SetText(L["Import"]);
    ImportButton:SetWidth(140);
    ImportButton:SetCallback("OnClick", function ()
        local srText = strtrim(softReservesBoxContent or "");
        local rsrText = strtrim(rollingExtraRollsContent or "");

        -- Route a Rolling SR string pasted into the top box to RollingSR
        if (srText ~= "" and rsrText == "" and not srText:find("\n") and (srText:find("^[^:,;\n]+:[^=;\n]+=%s*%d+") or srText:find("^[^:,;\n]+%*[aA][lL][tT]:") or srText:find("^[^:,;\n]+%*[rR][eE][cC][rR][uU][iI][tT]:"))) then
            rsrText = srText;
            srText = "";
        end

        if (srText ~= "") then
            GL.SoftRes:import(srText, true);
        end

        if (rsrText ~= "") then
            if (GL.RollingSR:parseImportString(rsrText)) then
                GL:success("Rolling SR extra rolls imported successfully");
                GL.RollingSR:broadcast();
                if (srText == "") then
                    self:close();
                end
            else
                GL:warning("Failed to parse Rolling SR extra rolls data");
            end
        elseif (srText == "") then
            GL.SoftRes:import("", true);
        end
    end);
    Window:AddChild(ImportButton);
end

-- Close the import frame and clean up after ourselves
function Importer:close()
    local Window = GL.Interface:get(self, "Window");

    if (not self.isVisible
        or not Window
    ) then
        return;
    end

    -- Store the frame's last position for future play sessions
    GL.Interface:storePosition(Window, "SoftReserveImport");

    -- Clear the frame and its widgets
    GL.Interface:release(Window);
    self.isVisible = false;
end
