package com.reznok.helloworld.controller;

import com.reznok.helloworld.domain.User;
import com.reznok.helloworld.repository.UserRepository;
import com.reznok.helloworld.security.SessionHelper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;

import javax.servlet.http.HttpServletRequest;
import java.util.Optional;

/**
 * User profile page.
 *
 * A01 Broken Access Control - IDOR:
 *  - /user/profile?id=N exposes any user object by id.
 *  - The page renders email & department of arbitrary users.
 *  - There is no check that id == currentUser.id.
 *  - Sequential ids make enumeration trivial (1..N).
 */
@Controller
public class UserController {

    private final UserRepository userRepository;
    private final SessionHelper sessionHelper;

    @Autowired
    public UserController(UserRepository userRepository, SessionHelper sessionHelper) {
        this.userRepository = userRepository;
        this.sessionHelper = sessionHelper;
    }

    @GetMapping("/user/profile")
    public String profile(@RequestParam(required = false) Long id,
                          Model model, HttpServletRequest req) {
        Optional<User> me = sessionHelper.currentUser(req);
        if (!me.isPresent()) return "redirect:/login";

        Long target = (id != null) ? id : me.get().getId();
        Optional<User> opt = userRepository.findById(target);
        if (!opt.isPresent()) return "redirect:/board";

        // ⚠ Missing: if (!target.equals(me.get().getId())
        //                 && !"ADMIN".equals(me.get().getRole())) reject
        model.addAttribute("profile", opt.get());
        model.addAttribute("currentUser", me.get());
        model.addAttribute("isSelf", target.equals(me.get().getId()));
        return "profile";
    }
}
