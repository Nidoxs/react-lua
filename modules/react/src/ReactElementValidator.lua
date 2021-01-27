-- upstream: https://github.com/facebook/react/blob/bc6b7b6b16f771bfc8048fe15e211ac777253b64/packages/react/src/ReactElementValidator.js
--[[*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 * @flow
*]]

--!nolint LocalShadowPedantic

local Workspace = script.Parent.Parent
local Packages = Workspace.Parent.Packages
local LuauPolyfill = require(Packages.LuauPolyfill)
local Array = LuauPolyfill.Array
local Object = LuauPolyfill.Object
local console = require(Workspace.Shared.console)

local isValidElementType = require(Workspace.Shared.isValidElementType)
local getComponentName = require(Workspace.Shared.getComponentName)
local ReactSymbols = require(Workspace.Shared.ReactSymbols)
local getIteratorFn = ReactSymbols.getIteratorFn
local REACT_FORWARD_REF_TYPE = ReactSymbols.REACT_FORWARD_REF_TYPE
local REACT_MEMO_TYPE = ReactSymbols.REACT_MEMO_TYPE
local REACT_FRAGMENT_TYPE = ReactSymbols.REACT_FRAGMENT_TYPE
local REACT_ELEMENT_TYPE = ReactSymbols.REACT_ELEMENT_TYPE

local warnAboutSpreadingKeyToJSX = require(Workspace.Shared.ReactFeatureFlags).warnAboutSpreadingKeyToJSX
local checkPropTypes = require(Workspace.Shared.checkPropTypes)
local ReactCurrentOwner = require(script.Parent.ReactCurrentOwner)

local ReactElement = require(script.Parent.ReactElement)
local isValidElement = ReactElement.isValidElement
local createElement = ReactElement.createElement
local cloneElement = ReactElement.cloneElement
local jsxDEV = ReactElement.jsxDEV

local setExtraStackFrame = require(script.Parent.ReactDebugCurrentFrame).setExtraStackFrame
local describeUnknownElementTypeFrameInDEV = require(Workspace.Shared.ReactComponentStackFrame)
	.describeUnknownElementTypeFrameInDEV

local exports = {}

local function setCurrentlyValidatingElement(element)
	if _G.__DEV__ then
		if element then
			local owner = element._owner
			local ownerArgument = nil
			if owner then
				ownerArgument = owner.type
			end
			local stack = describeUnknownElementTypeFrameInDEV(
				element.type,
				element._source,
				ownerArgument
			)
			setExtraStackFrame(stack)
		else
			setExtraStackFrame(nil)
		end
	end
end

local propTypesMisspellWarningShown

if _G.__DEV__ then
	propTypesMisspellWarningShown = false
end

local function hasOwnProperty(object, key)
	return object[key] ~= nil
end

local function getDeclarationErrorAddendum():string
	if ReactCurrentOwner.current then
		local name = getComponentName(ReactCurrentOwner.current.type)
		if name then
			return "\n\nCheck the render method of `" .. name .. "`."
		end
	end
	return ""
end

local function getSourceInfoErrorAddendum(source):string
	if source ~= nil then
		local fileName = source.fileName:gsub("^.*[\\/]", "")
		local lineNumber = source.lineNumber
		return "\n\nCheck your code at " .. fileName .. ":" .. lineNumber .. "."
	end
	return ""
end

local function getSourceInfoErrorAddendumForProps(elementProps):string
	if elementProps ~= nil then
		return getSourceInfoErrorAddendum(elementProps.__source)
	end
	return ""
end

-- /**
--  * Warn if there's no key explicitly set on dynamic arrays of children or
--  * object keys are not valid. This allows us to keep track of children between
--  * updates.
--  */
local ownerHasKeyUseWarning = {}

local function getCurrentComponentErrorInfo(parentType):string
	local info = getDeclarationErrorAddendum()

	if not info or info == "" then
		local parentName
		if typeof(parentType) == "string" then
			parentName = parentType
		else
			if typeof(parentType) == "table" then
				parentName = parentType.displayName or parentType.name
			end
		end

		if parentName then
			info = ("\n\nCheck the top-level render call using <%s>."):format(parentName)
		end
	end
	return info
end

-- /**
--  * Warn if the element doesn't have an explicit key assigned to it.
--  * This element is in an array. The array could grow and shrink or be
--  * reordered. All children that haven't already been validated are required to
--  * have a "key" property assigned to it. Error statuses are cached so a warning
--  * will only be shown once.
--  *
--  * @internal
--  * @param {ReactElement} element Element that requires a key.
--  * @param {*} parentType element's parent's type.
--  */
local function validateExplicitKey(element, parentType)
	if not element._store or element._store.validated or element.key ~= nil then
		return
	end
	element._store.validated = true

	local currentComponentErrorInfo = getCurrentComponentErrorInfo(parentType)
	if ownerHasKeyUseWarning[currentComponentErrorInfo] then
		return
	end
	ownerHasKeyUseWarning[currentComponentErrorInfo] = true

	-- // Usually the current owner is the offender, but if it accepts children as a
	-- // property, it may be the creator of the child that's responsible for
	-- // assigning it a key.
	local childOwner = ""
	if element
		and element._owner
		and element._owner ~= ReactCurrentOwner.current
	then
		-- // Give the component that originally created this child.
		childOwner = (" It was passed a child from %s."):format(
			getComponentName(element._owner.type)
		)
	end

	if _G.__DEV__ then
		setCurrentlyValidatingElement(element)
		console.error(
			'Each child in a list should have a unique "key" prop.' ..
				"%s%s See https://reactjs.org/link/warning-keys for more information.",
			currentComponentErrorInfo,
			childOwner
		)
		setCurrentlyValidatingElement(nil)
	end
end

-- /**
--  * Ensure that every element either is passed in a static location, in an
--  * array with an explicit keys property defined, or in an object literal
--  * with valid key property.
--  *
--  * @internal
--  * @param {ReactNode} node Statically passed child of any type.
--  * @param {*} parentType node's parent's type.
--  */
local function validateChildKeys(node, parentType)
	if typeof(node) ~= "table" then
		return
	end

	if Array.isArray(node) then
		for i = 1, #node do
			local child = node[i]
			if isValidElement(child) then
				validateExplicitKey(child, parentType)
			end
		end
	elseif isValidElement(node) then
		-- // This element was passed in a valid location.
		if node._store then
			node._store.validated = true
		end
	elseif node then
		local iteratorFn = getIteratorFn(node)
		if typeof(iteratorFn) == "function" then
			-- // Entry iterators used to provide implicit keys,
			-- // but now we print a separate warning for them later.
			if iteratorFn ~= node.entries then
				local iterator = iteratorFn(node)
				local step = iterator.next()
				while not step.done do
					if isValidElement(step.value) then
						validateExplicitKey(step.value, parentType)
					end

					step = iterator.next()
				end
			end
		end
	end
end

-- /**
--  * Given an element, validate that its props follow the propTypes definition,
--  * provided by the type.
--  *
--  * @param {ReactElement} element
--  */
local function validatePropTypes(element)
	if _G.__DEV__ then
		local type = element.type
		if type == nil or type == nil or typeof(type) == "string" then
			return
		end

		local propTypes
		if typeof(type) == "function" then
			-- deviation: function components can't have propTypes in Lua
			-- propTypes = type.propTypes
			return
		elseif typeof(type) == "table" and
			(
				type["$$typeof"] == REACT_FORWARD_REF_TYPE or
				-- // Note: Memo only checks outer props here.
				-- // Inner props are checked in the reconciler.
				type["$$typeof"] == REACT_MEMO_TYPE
			)
		then
			propTypes = type.propTypes
		else
			return
		end

		if propTypes then
			-- // Intentionally inside to avoid triggering lazy initializers:
			local name = getComponentName(type)
			checkPropTypes(propTypes, element.props, "prop", name, element)
		elseif type.PropTypes ~= nil and not propTypesMisspellWarningShown then
			propTypesMisspellWarningShown = true
			-- // Intentionally inside to avoid triggering lazy initializers:
			local name = getComponentName(type)
			console.error(
				"Component %s declared `PropTypes` instead of `propTypes`. Did you misspell the property assignment?",
				name or "Unknown"
			)
		end
		if typeof(type.getDefaultProps) == "function" and
			not type.getDefaultProps.isReactClassApproved
		then
			console.error(
				"getDefaultProps is only used on classic React.createClass " ..
					"definitions. Use a static property named `defaultProps` instead."
			)
		end
	end
end

-- /**
--  * Given a fragment, validate that it can only be provided with fragment props
--  * @param {ReactElement} fragment
--  */
local function validateFragmentProps(fragment)
	if _G.__DEV__ then
		local keys = Object.keys(fragment.props)
		for i = 1, #keys do
			local key = keys[i]
			if key ~= "children" and key ~= "key" then
				setCurrentlyValidatingElement(fragment)
				console.error(
					"Invalid prop `%s` supplied to `React.Fragment`. " ..
						"React.Fragment can only have `key` and `children` props.",
					key
				)
				setCurrentlyValidatingElement(nil)
				break
			end
		end

		if fragment.ref ~= nil then
			setCurrentlyValidatingElement(fragment)
			console.error("Invalid attribute `ref` supplied to `React.Fragment`.")
			setCurrentlyValidatingElement(nil)
		end
	end
end

local function jsxWithValidation(
	type,
	props,
	key,
	isStaticChildren,
	source,
	self
)
	local validType = isValidElementType(type)

	-- // We warn in this case but don't throw. We expect the element creation to
	-- // succeed and there will likely be errors in render.
	if not validType then
		local info = ""

		if type == nil or
			(
				typeof(type) == "table"
				and type ~= nil
				and #Object.keys(type) == 0
			)
		then
			info = info .. (
				" You likely forgot to export your component from the file " ..
					"it's defined in, or you might have mixed up default and named imports."
			)
		end

		local sourceInfo = getSourceInfoErrorAddendum(source)
		if sourceInfo then
			info = info .. sourceInfo
		else
			info = info .. getDeclarationErrorAddendum()
		end

		local typeString
		if type == nil then
			typeString = "nil"
		elseif Array.isArray(type) then
			typeString = "array"
		elseif type ~= nil and type["$$typeof"] == REACT_ELEMENT_TYPE then
			typeString = ("<%s />"):format(getComponentName(type.type) or "Unknown")
			info = " Did you accidentally export a JSX literal instead of a component?"
		else
			typeString = typeof(type)
		end

		if _G.__DEV__ then
			console.error(
				"React.jsx: type is invalid -- expected a string (for " ..
					"built-in components) or a class/function (for composite " ..
					"components) but got: %s.%s",
				typeString,
				info
			)
		end
	end

	local element = jsxDEV(type, props, key, source, self)

	-- // The result can be nullish if a mock or a custom function is used.
	-- // TODO: Drop this when these are no longer allowed as the type argument.
	if element == nil then
		return element
	end

	-- // Skip key warning if the type isn't valid since our key validation logic
	-- // doesn't expect a non-string/function type and can throw confusing errors.
	-- // We don't want exception behavior to differ between dev and prod.
	-- // (Rendering will throw with a helpful message and as soon as the type is
	-- // fixed, the key warnings will appear.)

	if validType then
		local children = props.children
		if children ~= nil then
			if isStaticChildren then
				if Array.isArray(children) then
					for i = 1, #children do
						validateChildKeys(children[i], type)
					end

					-- deviation: Object.freeze always exist
					-- if Object.freeze then
					Object.freeze(children)
					-- end
				else
					if _G.__DEV__ then
						console.error(
							"React.jsx: Static children should always be an array. " ..
								"You are likely explicitly calling React.jsxs or React.jsxDEV. " ..
								"Use the Babel transform instead."
						)
					end
				end
			else
				validateChildKeys(children, type)
			end
		end
	end

	if _G.__DEV__ then
		if warnAboutSpreadingKeyToJSX then
			if hasOwnProperty(props, "key") then
				console.error(
					"React.jsx: Spreading a key to JSX is a deprecated pattern. " ..
						"Explicitly pass a key after spreading props in your JSX call. " ..
						"E.g. <%s {...props} key={key} />",
					getComponentName(type) or "ComponentName"
				)
			end
		end
	end

	if type == REACT_FRAGMENT_TYPE then
		validateFragmentProps(element)
	else
		validatePropTypes(element)
	end

	return element
end
exports.jsxWithValidation = jsxWithValidation

-- // These two functions exist to still get child warnings in dev
-- // even with the prod transform. This means that jsxDEV is purely
-- // opt-in behavior for better messages but that we won't stop
-- // giving you warnings if you use production apis.
exports.jsxWithValidationStatic = function(type, props, key)
	return jsxWithValidation(type, props, key, true)
end

exports.jsxWithValidationDynamic = function(type, props, key)
	return jsxWithValidation(type, props, key, false)
end

local function createElementWithValidation(type, props, ...)
	local arguments = { type, props, ... }

	local validType = isValidElementType(type)

	-- // We warn in this case but don't throw. We expect the element creation to
	-- // succeed and there will likely be errors in render.
	if not validType then
		local info = ""
		if type == nil or
			(
				typeof(type) == "table" and
				type ~= nil and
				#Object.keys(type) == 0
			)
		then
			info = info .. (
				" You likely forgot to export your component from the file " ..
					"it's defined in, or you might have mixed up default and named imports."
			)
		end

		local sourceInfo = getSourceInfoErrorAddendumForProps(props)
		if sourceInfo then
			info = info .. sourceInfo
		else
			info = info .. getDeclarationErrorAddendum()
		end

		local typeString
		if type == nil then
			typeString = "nil"
		elseif Array.isArray(type) then
			typeString = "array"
		elseif type ~= nil and typeof(type) == "table" and type["$$typeof"] == REACT_ELEMENT_TYPE then
			typeString = ("<%s />"):format(getComponentName(type.type) or "Unknown")
			info = " Did you accidentally export a JSX literal instead of a component?"
		else
			typeString = typeof(type)
		end

		if _G.__DEV__ then
			console.error(
				"React.createElement: type is invalid -- expected a string (for " ..
					"built-in components) or a class/function (for composite " ..
					"components) but got: %s.%s",
				typeString,
				info
			)
		end
	end

	local element = createElement(unpack(arguments))

	-- // The result can be nullish if a mock or a custom function is used.
	-- // TODO: Drop this when these are no longer allowed as the type argument.
	if element == nil then
		return element
	end

	-- // Skip key warning if the type isn't valid since our key validation logic
	-- // doesn't expect a non-string/function type and can throw confusing errors.
	-- // We don't want exception behavior to differ between dev and prod.
	-- // (Rendering will throw with a helpful message and as soon as the type is
	-- // fixed, the key warnings will appear.)
	if validType then
		for i=3, #arguments do
			validateChildKeys(arguments[i], type)
		end
	end

	if type == REACT_FRAGMENT_TYPE then
		validateFragmentProps(element)
	else
		validatePropTypes(element)
	end

	return element
end
exports.createElementWithValidation = createElementWithValidation

-- devitation: createFactory is deprecated and will be removed
-- local didWarnAboutDeprecatedCreateFactory = false

-- exports.createFactoryWithValidation = function(type)
-- 	local validatedFactory = function(...)
-- 		createElementWithValidation(type, ...)
-- 	end
-- 	-- deviation: Lua can't assign fields to functions. The 'type'
-- 	-- property is deprecated so there is no need to port this over.
-- 	-- validatedFactory.type = type

-- 	if _G.__DEV__ then
-- 		if not didWarnAboutDeprecatedCreateFactory then
-- 			didWarnAboutDeprecatedCreateFactory = true
-- 			console.warn(
-- 				"React.createFactory() is deprecated and will be removed in " ..
-- 					"a future major release. Consider using JSX " ..
-- 					"or use React.createElement() directly instead."
-- 			)
-- 		end
-- 		-- // Legacy hook: remove it
-- 		-- deviation: no porting this behavior because it is deprecated
-- 		-- Object.defineProperty(validatedFactory, "type", {
-- 		-- 	enumerable = false,
-- 		-- 	get = function()
-- 		-- 		console.warn(
-- 		-- 			"Factory.type is deprecated. Access the class directly " ..
-- 		-- 				"before passing it to createFactory."
-- 		-- 		)
-- 		-- 		Object.defineProperty(this, "type", {
-- 		-- 			value = type,
-- 		-- 		})
-- 		-- 		return type
-- 		-- 	end,
-- 		-- })
-- 	end

-- 	return validatedFactory
-- end

exports.cloneElementWithValidation = function(element, props, ...)
	local arguments = { element, props, ... }
	local newElement = cloneElement(unpack(arguments))
	for i=3, #arguments do
		validateChildKeys(arguments[i], newElement.type)
	end
	validatePropTypes(newElement)
	return newElement
end

return exports
