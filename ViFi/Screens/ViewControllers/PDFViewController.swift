//
//  PDFViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 16.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import Firebase
import FirebaseDatabase
import SafariServices

class PDFViewController: UIViewController, SFSafariViewControllerDelegate {
    
    var uniName = String()
    var facName = String()
    var depName = String()
    var lessonName = String()
    var examName = String()
    var pdfURLArray = [String]()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable

        navigationItem.title = examName
        
        getDataFromFireBase()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
    }
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        dataBaseRefence.child("Universities").child(uniName).child(facName).child(depName).child(lessonName).child(examName).observe(DataEventType.childAdded) { (snapshot) in
            
            for child in snapshot.children {
                if let childSnapshot = child as? DataSnapshot,
                    let value = childSnapshot.childSnapshot(forPath: "downloadURL").value as? String {
                    self.pdfURLArray.append(value)
                }
            }
            let safariVC = SFSafariViewController(url: (NSURL(string: self.pdfURLArray[0])! as NSURL) as URL)
            self.present(safariVC, animated: true, completion: nil)
            safariVC.delegate = self
        }
    }
    
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        controller.dismiss(animated: true, completion: nil)
    }
}
